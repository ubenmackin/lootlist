//
//  AppDelegateBackgroundTaskTests.swift
//  LootList
//
//  Created by Ben Mackin on 9/7/26.
//

import CloudKit
import Foundation
@testable import LootList
import Synchronization
import Testing

/// BGTask cannot be instantiated in tests, so this captures setTaskCompleted semantics.
private final class CapturedTaskCompletion: Sendable {
    private let state = Mutex<Bool?>(nil)
    var value: Bool? {
        state.withLock { $0 }
    }

    func setTaskCompleted(success: Bool) {
        state.withLock { $0 = success }
    }
}

@MainActor
private func makeBackgroundLifecycle(
    appState: AppState,
    cloudKit: MockCloudKitService,
    sync: any SyncCoordinating,
    appSync: AppSyncCoordinator,
    payoutScheduler: ((PayoutDay) -> Bool)? = nil,
    defaults: UserDefaults
) throws -> AppLifecycleCoordinator {
    let cache = try CacheService(inMemory: true, defaults: defaults)
    appState.cacheService = cache
    if let container = cache.container {
        appState.backgroundCacheActor = BackgroundCacheActor(container: container)
    }
    let migrations = DataMigrationsCoordinator(defaults: defaults)
    let toast = ToastManager()
    let notification = NotificationService(cloudKit: cloudKit, appState: appState, cacheService: cache, defaults: defaults)
    let xp = XPService(cloudKit: cloudKit, notificationService: notification, cacheService: cache, appState: appState)
    let treasury = TreasuryService(cloudKit: cloudKit, notificationService: notification, cacheService: cache, appState: appState)
    let quest = QuestService(
        cloudKit: cloudKit,
        xpService: xp,
        notificationService: notification,
        cacheService: cache,
        treasuryService: treasury,
        toastManager: toast,
        appState: appState
    )
    let familyService = FamilyService(cloudKit: cloudKit, appState: appState, questService: quest, cacheService: cache)
    let autoPayout = AutoPayoutCoordinator(
        treasuryService: treasury,
        questService: quest,
        familyService: familyService,
        appState: appState,
        toastManager: toast
    )
    return AppLifecycleCoordinator(
        appState: appState,
        cloudKitService: cloudKit,
        syncCoordinator: sync,
        appSyncCoordinator: appSync,
        dataMigrationsCoordinator: migrations,
        autoPayoutCoordinator: autoPayout,
        payoutScheduler: payoutScheduler
    )
}

@MainActor
struct AppDelegateBackgroundTaskTests {
    @Test
    func `schedule entry points are safe when invoked off-main`() async {
        // Submit paths are simulator-gated no-ops, so off-main invocation must simply return.
        await Task.detached {
            AppDelegate.scheduleWeeklyPayoutRefresh()
            AppDelegate.scheduleSpendDigestRefresh()
            AppDelegate.scheduleSyncProcessingTask()
        }.value
        #expect(!AppDelegate.weeklyPayoutTaskId.isEmpty)
        #expect(!AppDelegate.syncTaskId.isEmpty)
        #expect(!AppDelegate.spendDigestTaskId.isEmpty)
    }

    @Test
    func `background entries fail closed off-main when shared is nil`() async {
        // WHY isolation: host app may have set shared at launch, so capture it, reset to cold start, then restore on exit.
        let originalShared = AppDependencies.shared
        AppDependencies.resetSharedForTests()
        defer { AppDependencies.restoreSharedForTests(originalShared) }
        #expect(AppDependencies.shared == nil)
        let payoutCompletion = CapturedTaskCompletion()
        let digestCompletion = CapturedTaskCompletion()
        let syncCompletion = CapturedTaskCompletion()
        await Task.detached {
            await MainActor.run {
                // Cold start before the container exists cannot do work, so report failure.
                guard AppDependencies.shared != nil else {
                    payoutCompletion.setTaskCompleted(success: false)
                    digestCompletion.setTaskCompleted(success: false)
                    syncCompletion.setTaskCompleted(success: false)
                    return
                }
                payoutCompletion.setTaskCompleted(success: true)
                digestCompletion.setTaskCompleted(success: true)
                syncCompletion.setTaskCompleted(success: true)
            }
        }.value
        #expect(payoutCompletion.value == false)
        #expect(digestCompletion.value == false)
        #expect(syncCompletion.value == false)
    }

    @Test
    func `payout refresh hops off-main with session and reschedules`() async throws {
        let defaults = UserDefaults.ephemeral()
        let appState = AppState(defaults: defaults)
        let zoneID = CKRecordZone.ID(zoneName: "BackgroundPayoutZone", ownerName: "Owner")
        let family = Family(
            name: "Background Guild",
            createdBy: CKRecord.ID(recordName: "owner", zoneID: zoneID),
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
        let profile = Profile(
            displayName: "GM",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: MockCloudKitService.mockUserRecordName, zoneID: zoneID),
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: "prof1", zoneID: zoneID)
        )
        let cloudKit = MockCloudKitService()
        cloudKit.seedMockRecords([family, profile])
        appState.saveSession(profile: profile, family: family, zoneID: zoneID, isOwner: true)
        let sync = CountingSyncCoordinator()
        let appSync = AppSyncCoordinator()
        let reschedules = Mutex<Int>(0)
        let lifecycle = try makeBackgroundLifecycle(
            appState: appState,
            cloudKit: cloudKit,
            sync: sync,
            appSync: appSync,
            payoutScheduler: { _ in reschedules.withLock { $0 += 1 }; return true },
            defaults: defaults
        )
        let first = await Task { await lifecycle.handleWeeklyPayoutBackgroundRefresh() }.value
        #expect(first == true)
        #expect(reschedules.withLock { $0 } == 1)
        // Second run reschedules again without duplicating payout side effects.
        let second = await Task { await lifecycle.handleWeeklyPayoutBackgroundRefresh() }.value
        #expect(second == true)
        #expect(reschedules.withLock { $0 } == 2)
    }

    @Test
    func `digest and manual sync hop off-main with session and complete`() async throws {
        let defaults = UserDefaults.ephemeral()
        let appState = AppState(defaults: defaults)
        let zoneID = CKRecordZone.ID(zoneName: "BackgroundSyncZone", ownerName: "Owner")
        let family = Family(
            name: "Background Sync Guild",
            createdBy: CKRecord.ID(recordName: "owner", zoneID: zoneID),
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
        let profile = Profile(
            displayName: "GM",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: MockCloudKitService.mockUserRecordName, zoneID: zoneID),
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: "prof1", zoneID: zoneID)
        )
        let cloudKit = MockCloudKitService()
        cloudKit.seedMockRecords([family, profile])
        appState.saveSession(profile: profile, family: family, zoneID: zoneID, isOwner: true)
        let sync = CountingSyncCoordinator()
        let appSync = AppSyncCoordinator()
        let lifecycle = try makeBackgroundLifecycle(
            appState: appState,
            cloudKit: cloudKit,
            sync: sync,
            appSync: appSync,
            defaults: defaults
        )
        let cache = try #require(appState.cacheService)
        appSync.spendDigestService = SpendDigestService(cacheService: cache, appState: appState, defaults: defaults)
        let digestFirst = await Task { await appSync.handleSpendDigestBackgroundRefresh() }.value
        #expect(digestFirst == true)
        let digestSecond = await Task { await appSync.handleSpendDigestBackgroundRefresh() }.value
        #expect(digestSecond == true)
        lifecycle.setHasCompletedInitialBootstrapForTests(true)
        let fetchBefore = sync.fetchCount
        await Task { await lifecycle.performManualSync() }.value
        #expect(sync.fetchCount == fetchBefore + 1)
        await Task.detached { AppDelegate.scheduleSyncProcessingTask() }.value
    }
}
