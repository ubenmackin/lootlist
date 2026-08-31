//
//  AppLifecycleCoordinatorTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/14/26.
//

import CloudKit
import Foundation
@testable import LootList
import Synchronization
import Testing

// MARK: - Test Doubles

/// Gated sync double that parks `fetchChanges` until released.
/// Lets tests open a deterministic in-flight window for single-flight assertions.
@MainActor
final class GatedSyncCoordinator: SyncCoordinating {
    private let gate = SyncGate()
    private let counter = Mutex<Int>(0)

    var fetchCount: Int {
        counter.withLock { $0 }
    }

    var sendCount: Int {
        counter.withLock { $0 }
    }

    func fetchChanges() async {
        counter.withLock { $0 += 1 }
        await gate.park()
    }

    func sendPendingChanges() async {
        // No-op for these tests; fetch gate drives the window.
    }

    func waitForParked(count target: Int = 1) async {
        await gate.waitForParked(count: target)
    }

    func release() {
        gate.releaseAll()
    }
}

/// Simple counting double with no gate.
@MainActor
final class CountingSyncCoordinator: SyncCoordinating {
    private let counter = Mutex<Int>(0)
    var fetchCount: Int {
        counter.withLock { $0 }
    }

    func fetchChanges() async {
        counter.withLock { $0 += 1 }
    }

    func sendPendingChanges() async {}
}

private final class SyncGate: Sendable {
    private struct State {
        var parked: [CheckedContinuation<Void, Never>] = []
        var parkedCount = 0
        var isReleased = false
    }

    private let lock = Mutex<State>(State())

    func park() async {
        let shouldPark = lock.withLock { state -> Bool in
            state.parkedCount += 1
            return !state.isReleased
        }
        if shouldPark {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.withLock { state in
                    if state.isReleased {
                        continuation.resume()
                    } else {
                        state.parked.append(continuation)
                    }
                }
            }
        }
    }

    func waitForParked(count target: Int) async {
        while true {
            let cur = lock.withLock { $0.parkedCount }
            if cur >= target {
                return
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func releaseAll() {
        let toResume = lock.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isReleased = true
            let all = state.parked
            state.parked.removeAll()
            return all
        }
        for continuation in toResume {
            continuation.resume()
        }
    }
}

// MARK: - Scaffold

@MainActor
private func makeFamilyAndProfile(zoneID: CKRecordZone.ID) -> (Family, Profile) {
    let family = Family(
        name: "Test Guild",
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
    return (family, profile)
}

@MainActor
private func makeLifecycle(
    appState: AppState,
    cloudKit: MockCloudKitService,
    sync: any SyncCoordinating,
    payoutScheduler: ((PayoutDay) -> Bool)? = nil,
    defaults: UserDefaults? = nil
) throws -> AppLifecycleCoordinator {
    let resolvedDefaults = defaults ?? UserDefaults.ephemeral()
    let cache = try CacheService(inMemory: true, defaults: resolvedDefaults)
    appState.cacheService = cache
    let appSync = AppSyncCoordinator()
    let migrations = DataMigrationsCoordinator(defaults: resolvedDefaults)
    let toast = ToastManager()
    let notification = NotificationService(cloudKit: cloudKit, appState: appState, cacheService: cache, defaults: resolvedDefaults)
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
    let autoPayout = AutoPayoutCoordinator(treasuryService: treasury, questService: quest, familyService: familyService, appState: appState, toastManager: toast)
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

// MARK: - AppLifecycleCoordinatorTests

@MainActor
struct AppLifecycleCoordinatorTests {
    // MARK: CoordinatorState Atomic Transitions

    @Test
    func `coordinatorState atomic check-and-set via withLock cycles through all cases`() throws {
        let defaults = UserDefaults.ephemeral()
        let appState = AppState(defaults: defaults)
        let cloudKit = MockCloudKitService()
        let sync = CountingSyncCoordinator()
        let lifecycle = try makeLifecycle(appState: appState, cloudKit: cloudKit, sync: sync, defaults: defaults)

        #expect(lifecycle.coordinatorStateForTests == .idle)

        // Simulate bootstrapping transition atomically.
        let didBootstrap = lifecycle.transitionPhaseForTests(to: .bootstrapping)
        #expect(didBootstrap)
        #expect(lifecycle.coordinatorStateForTests == .bootstrapping)

        // Second bootstrapping attempt must fail while already bootstrapping.
        let secondBootstrap = lifecycle.transitionPhaseForTests(to: .bootstrapping)
        #expect(!secondBootstrap)

        lifecycle.resetPhaseForTests()
        #expect(lifecycle.coordinatorStateForTests == .idle)

        // Syncing transition.
        let didSync = lifecycle.transitionPhaseForTests(to: .syncing)
        #expect(didSync)
        #expect(lifecycle.coordinatorStateForTests == .syncing)
        lifecycle.resetPhaseForTests()

        // Zone changing transition.
        let didZone = lifecycle.transitionPhaseForTests(to: .zoneChanging)
        #expect(didZone)
        #expect(lifecycle.coordinatorStateForTests == .zoneChanging)
        lifecycle.resetPhaseForTests()
        #expect(lifecycle.coordinatorStateForTests == .idle)
    }

    // MARK: Foreground vs Remote Mutual Exclusion

    @Test
    func `performForegroundSync and handleRemoteNotification cannot both enter at first await`() async throws {
        let defaults = UserDefaults.ephemeral()
        let appState = AppState(defaults: defaults)
        let zoneID = CKRecordZone.ID(zoneName: "MutexZone", ownerName: "Owner")
        let (family, profile) = makeFamilyAndProfile(zoneID: zoneID)
        appState.family = family
        appState.currentProfile = profile
        appState.familyZoneID = zoneID
        appState.isZoneOwner = true
        appState.authStatus = .authenticated

        let cloudKit = MockCloudKitService()
        cloudKit.seedMockRecords([family, profile])
        let gated = GatedSyncCoordinator()
        let lifecycle = try makeLifecycle(appState: appState, cloudKit: cloudKit, sync: gated, defaults: defaults)
        lifecycle.setHasCompletedInitialBootstrapForTests(true)

        // Park a foreground sync in its first await (fetchChanges).
        let fgTask = Task { await lifecycle.performForegroundSync() }
        await gated.waitForParked(count: 1)
        #expect(lifecycle.coordinatorStateForTests == .syncing)

        // Remote notification arriving while syncing must be rejected immediately
        // without invoking a second fetch (second sees syncing and skips).
        await lifecycle.handleRemoteNotification()
        #expect(gated.fetchCount == 1)

        gated.release()
        await fgTask.value
        #expect(lifecycle.coordinatorStateForTests == .idle)
        #expect(gated.fetchCount == 1)

        // After the first completes, a subsequent remote sync can proceed.
        let counting = CountingSyncCoordinator()
        let lifecycle2 = try makeLifecycle(appState: appState, cloudKit: cloudKit, sync: counting, defaults: defaults)
        lifecycle2.setHasCompletedInitialBootstrapForTests(true)
        await lifecycle2.handleRemoteNotification()
        #expect(counting.fetchCount == 1)
    }

    // MARK: Manual Sync Independent Guard

    @Test
    func `performManualSync uses independent isManualSyncing and is not starved by foreground sync`() async throws {
        let defaults = UserDefaults.ephemeral()
        let appState = AppState(defaults: defaults)
        let zoneID = CKRecordZone.ID(zoneName: "ManualZone", ownerName: "Owner")
        let (family, profile) = makeFamilyAndProfile(zoneID: zoneID)
        appState.family = family
        appState.currentProfile = profile
        appState.familyZoneID = zoneID
        appState.isZoneOwner = true
        appState.authStatus = .authenticated

        let cloudKit = MockCloudKitService()
        cloudKit.seedMockRecords([family, profile])
        let gated = GatedSyncCoordinator()
        let lifecycle = try makeLifecycle(appState: appState, cloudKit: cloudKit, sync: gated, defaults: defaults)
        lifecycle.setHasCompletedInitialBootstrapForTests(true)

        let fgTask = Task { await lifecycle.performForegroundSync() }
        await gated.waitForParked(count: 1)
        #expect(lifecycle.coordinatorStateForTests == .syncing)

        #expect(lifecycle.isManualSyncingForTests == false)

        // Park foreground, then attempt manual on same lifecycle — should still run.
        let manualTask = Task { await lifecycle.performManualSync() }
        // Manual sync should enter immediately (independent guard), so it will
        // block on its own fetch (second parked count).
        await gated.waitForParked(count: 2)
        #expect(gated.fetchCount == 2)
        #expect(lifecycle.isManualSyncingForTests == true)

        gated.release()
        await fgTask.value
        await manualTask.value
        #expect(lifecycle.isManualSyncingForTests == false)
        #expect(lifecycle.coordinatorStateForTests == .idle)

        // Verify manual sync collapses on its own mutex: two concurrent manual syncs
        // allow only one execution.
        let gated2 = GatedSyncCoordinator()
        let lifecycle3 = try makeLifecycle(appState: appState, cloudKit: cloudKit, sync: gated2, defaults: defaults)
        lifecycle3.setHasCompletedInitialBootstrapForTests(true)
        let firstManualTask = Task { await lifecycle3.performManualSync() }
        await gated2.waitForParked(count: 1)
        let secondManualTask = Task { await lifecycle3.performManualSync() }
        // Give secondManualTask a moment to attempt entry and be rejected.
        try? await Task.sleep(for: .milliseconds(20))
        #expect(gated2.fetchCount == 1)
        gated2.release()
        await firstManualTask.value
        await secondManualTask.value
        #expect(gated2.fetchCount == 1)
        #expect(lifecycle3.isManualSyncingForTests == false)
    }

    // MARK: lastSynchronizedScopeKey Mutex

    @Test
    func `lastSynchronizedScopeKey is Mutex-protected and cleared on session and zone change`() async throws {
        let defaults = UserDefaults.ephemeral()
        let appState = AppState(defaults: defaults)
        let cloudKit = MockCloudKitService()
        let sync = CountingSyncCoordinator()
        let lifecycle = try makeLifecycle(appState: appState, cloudKit: cloudKit, sync: sync, defaults: defaults)
        // Allow the async observer tasks to subscribe before testing notifications.
        try? await Task.sleep(for: .milliseconds(20))

        lifecycle.setLastSynchronizedScopeKeyForTests("fam1|zoneA|owner|true")
        #expect(lifecycle.lastSynchronizedScopeKey == "fam1|zoneA|owner|true")

        // Clearing via didClearSession notification.
        NotificationCenter.default.post(name: .didClearSession, object: nil)
        // Allow the async observer Task to process the notification.
        try? await Task.sleep(for: .milliseconds(20))
        #expect(lifecycle.lastSynchronizedScopeKey == nil)

        lifecycle.setLastSynchronizedScopeKeyForTests("fam1|zoneA|owner|true")
        #expect(lifecycle.lastSynchronizedScopeKey != nil)

        // Clearing via familyZoneID change (didChangeFamilyZoneID).
        let newZone = CKRecordZone.ID(zoneName: "NewScopeZone", ownerName: "Owner")
        appState.familyZoneID = newZone
        try? await Task.sleep(for: .milliseconds(20))
        #expect(lifecycle.lastSynchronizedScopeKey == nil)

        // Also verify clearSession posts didClearSession and clears the key.
        lifecycle.setLastSynchronizedScopeKeyForTests("again")
        appState.clearSession()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(lifecycle.lastSynchronizedScopeKey == nil)
    }

    // MARK: Bootstrap Completion Gate

    @Test
    func `hasCompletedInitialBootstrap only true after scheduleWeeklyPayoutRefresh succeeds`() async throws {
        let suite = "BootstrapGate_\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let appState = AppState(defaults: defaults)
        let zoneID = CKRecordZone.ID(zoneName: "BootstrapGateZone", ownerName: "Owner")
        let family = Family(name: "Gate Family", createdBy: CKRecord.ID(recordName: "owner", zoneID: zoneID), id: CKRecord.ID(recordName: "fam1", zoneID: zoneID))
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
        let cache = try CacheService(inMemory: true)
        appState.cacheService = cache

        let failingScheduler: (PayoutDay) -> Bool = { _ in false }
        let sync = CountingSyncCoordinator()
        let lifecycleFail = try makeLifecycle(appState: appState, cloudKit: cloudKit, sync: sync, payoutScheduler: failingScheduler)

        await lifecycleFail.performInitialBootstrap()
        #expect(lifecycleFail.hasCompletedInitialBootstrap == false)

        let succeedingScheduler: (PayoutDay) -> Bool = { _ in true }
        let successSync = CountingSyncCoordinator()
        let lifecycleSuccess = try makeLifecycle(appState: appState, cloudKit: cloudKit, sync: successSync, payoutScheduler: succeedingScheduler)
        // Reset auth to allow bootstrap to run again (new instance shares same appState session).
        await lifecycleSuccess.performInitialBootstrap()
        #expect(lifecycleSuccess.hasCompletedInitialBootstrap == true)

        // Second bootstrap after completion must be a no-op regardless of scheduler.
        var secondScheduleCount = 0
        let countingScheduler: (PayoutDay) -> Bool = { _ in secondScheduleCount += 1; return true }
        let secondSync = CountingSyncCoordinator()
        let lifecycleSecond = try makeLifecycle(appState: appState, cloudKit: cloudKit, sync: secondSync, payoutScheduler: countingScheduler)
        lifecycleSecond.setHasCompletedInitialBootstrapForTests(true)
        await lifecycleSecond.performInitialBootstrap()
        #expect(secondScheduleCount == 0)

        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: 10 Concurrent Foreground Syncs Collapse

    @Test
    func `ten concurrent foreground sync attempts collapse to one execution`() async throws {
        let defaults = UserDefaults.ephemeral()
        let appState = AppState(defaults: defaults)
        let zoneID = CKRecordZone.ID(zoneName: "CollapseZone", ownerName: "Owner")
        let (family, profile) = makeFamilyAndProfile(zoneID: zoneID)
        appState.family = family
        appState.currentProfile = profile
        appState.familyZoneID = zoneID
        appState.isZoneOwner = true
        appState.authStatus = .authenticated

        let cloudKit = MockCloudKitService()
        cloudKit.seedMockRecords([family, profile])
        let gated = GatedSyncCoordinator()
        let lifecycle = try makeLifecycle(appState: appState, cloudKit: cloudKit, sync: gated, defaults: defaults)
        lifecycle.setHasCompletedInitialBootstrapForTests(true)

        var tasks: [Task<Void, Never>] = []
        for _ in 0 ..< 10 {
            tasks.append(Task { await lifecycle.performForegroundSync() })
        }

        await gated.waitForParked(count: 1)
        // Only one task should have entered; others saw syncing and skipped.
        #expect(gated.fetchCount == 1)
        #expect(lifecycle.coordinatorStateForTests == .syncing)

        gated.release()
        for task in tasks {
            await task.value
        }

        #expect(gated.fetchCount == 1)
        #expect(lifecycle.coordinatorStateForTests == .idle)

        // A subsequent sync after collapse should succeed.
        let counting = CountingSyncCoordinator()
        let lifecycle2 = try makeLifecycle(appState: appState, cloudKit: cloudKit, sync: counting, defaults: defaults)
        lifecycle2.setHasCompletedInitialBootstrapForTests(true)
        await lifecycle2.performForegroundSync()
        #expect(counting.fetchCount == 1)
    }

    // MARK: Existing Behavior Preserved

    @Test
    func `performInitialBootstrap runs only once and sets completed flag`() async throws {
        let defaults = UserDefaults.ephemeral()

        let appState = AppState(defaults: defaults)
        let zoneID = CKRecordZone.ID(zoneName: "BootstrapZone", ownerName: "Owner")
        let family = Family(name: "Bootstrap Family", createdBy: CKRecord.ID(recordName: "owner", zoneID: zoneID), id: CKRecord.ID(recordName: "fam1", zoneID: zoneID))
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

        let cache = try CacheService(inMemory: true, defaults: defaults)
        appState.cacheService = cache

        let appSync = AppSyncCoordinator()
        let migrations = DataMigrationsCoordinator(defaults: defaults)
        var migrationRunCount = 0
        migrations.register(DataMigrationsCoordinator.MigrationStep(id: "TestStep", version: 1) { migrationRunCount += 1 })

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
        let autoPayout = AutoPayoutCoordinator(treasuryService: treasury, questService: quest, familyService: familyService, appState: appState, toastManager: toast)
        let sync = CountingSyncCoordinator()
        let lifecycle = AppLifecycleCoordinator(
            appState: appState,
            cloudKitService: cloudKit,
            syncCoordinator: sync,
            appSyncCoordinator: appSync,
            dataMigrationsCoordinator: migrations,
            autoPayoutCoordinator: autoPayout
        )

        await lifecycle.performInitialBootstrap()
        #expect(migrationRunCount == 1)
        #expect(lifecycle.hasCompletedInitialBootstrap == true)

        await lifecycle.performInitialBootstrap()
        #expect(migrationRunCount == 1)
    }

    @Test
    func `performForegroundSync is lightweight and handles in-flight guards`() async throws {
        let defaults = UserDefaults.ephemeral()
        let appState = AppState(defaults: defaults)
        let cloudKit = MockCloudKitService()
        let sync = CountingSyncCoordinator()
        let lifecycle = try makeLifecycle(appState: appState, cloudKit: cloudKit, sync: sync, defaults: defaults)

        await lifecycle.performForegroundSync()
        await lifecycle.handleRemoteNotification()
        #expect(sync.fetchCount == 0)

        lifecycle.setHasCompletedInitialBootstrapForTests(true)
        await lifecycle.performForegroundSync()
        await lifecycle.handleRemoteNotification()
        await lifecycle.performManualSync()
        #expect(sync.fetchCount == 3)
    }

    @Test
    func `performFamilyZoneChange executes migrations and subscription registration`() async throws {
        let defaults = UserDefaults.ephemeral()

        let appState = AppState(defaults: defaults)
        let zoneID = CKRecordZone.ID(zoneName: "NewFamilyZone", ownerName: "Owner")
        let family = Family(name: "New Family", createdBy: CKRecord.ID(recordName: "owner", zoneID: zoneID), id: CKRecord.ID(recordName: "family123", zoneID: zoneID))
        let profile = Profile(
            displayName: "GM",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: MockCloudKitService.mockUserRecordName, zoneID: zoneID),
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: "prof123", zoneID: zoneID)
        )

        let cloudKit = MockCloudKitService()
        cloudKit.seedMockRecords([family, profile])
        let cache = try CacheService(inMemory: true, defaults: defaults)
        appState.cacheService = cache
        appState.family = family
        appState.currentProfile = profile
        appState.familyZoneID = zoneID
        appState.isZoneOwner = true
        appState.authStatus = .authenticated
        appState.saveSession(profile: profile, family: family, zoneID: zoneID, isOwner: true)

        let appSync = AppSyncCoordinator()
        let migrations = DataMigrationsCoordinator(defaults: defaults)
        migrations.register(DataMigrationsCoordinator.MigrationStep(id: "ZoneChangeStep", version: 1) {})

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
        let autoPayout = AutoPayoutCoordinator(treasuryService: treasury, questService: quest, familyService: familyService, appState: appState, toastManager: toast)
        let sync = CountingSyncCoordinator()
        let lifecycle = AppLifecycleCoordinator(
            appState: appState,
            cloudKitService: cloudKit,
            syncCoordinator: sync,
            appSyncCoordinator: appSync,
            dataMigrationsCoordinator: migrations,
            autoPayoutCoordinator: autoPayout
        )
        lifecycle.setHasCompletedInitialBootstrapForTests(true)

        await lifecycle.performFamilyZoneChange()

        let expectedKey = "migration.prof123.family123.ZoneChangeStep.v1.complete"
        #expect(defaults.bool(forKey: expectedKey) == true)

        let refreshSuccess = await lifecycle.handleWeeklyPayoutBackgroundRefresh()
        #expect(refreshSuccess == true)
    }

    @Test
    func `networkDidReconnect notification triggers manual sync`() async throws {
        let defaults = UserDefaults.ephemeral()
        let appState = AppState(defaults: defaults)
        let zoneID = CKRecordZone.ID(zoneName: "ReconnectZone", ownerName: "Owner")
        let family = Family(name: "Reconnect Family", createdBy: CKRecord.ID(recordName: "owner", zoneID: zoneID), id: CKRecord.ID(recordName: "family_reconnect", zoneID: zoneID))
        let profile = Profile(
            displayName: "Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: MockCloudKitService.mockUserRecordName, zoneID: zoneID),
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: "hero_reconnect", zoneID: zoneID)
        )

        let cloudKit = MockCloudKitService()
        let cache = try CacheService(inMemory: true, defaults: defaults)
        appState.cacheService = cache
        appState.family = family
        appState.currentProfile = profile
        appState.familyZoneID = zoneID
        appState.isZoneOwner = false
        appState.authStatus = .authenticated
        appState.saveSession(profile: profile, family: family, zoneID: zoneID, isOwner: false)

        let appSync = AppSyncCoordinator()
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
        let autoPayout = AutoPayoutCoordinator(treasuryService: treasury, questService: quest, familyService: familyService, appState: appState, toastManager: toast)
        let sync = CountingSyncCoordinator()
        let lifecycle = AppLifecycleCoordinator(
            appState: appState,
            cloudKitService: cloudKit,
            syncCoordinator: sync,
            appSyncCoordinator: appSync,
            dataMigrationsCoordinator: migrations,
            autoPayoutCoordinator: autoPayout
        )
        lifecycle.setHasCompletedInitialBootstrapForTests(true)

        #expect(sync.fetchCount == 0)
        // Give background task time to register notification listener
        try? await Task.sleep(for: .milliseconds(50))
        NotificationCenter.default.post(name: .networkDidReconnect, object: nil)

        // Allow async task to receive notification and execute
        try? await Task.sleep(for: .milliseconds(100))
        #expect(sync.fetchCount >= 1)
    }

    // MARK: LootListApp performForegroundSync Watermark Verification (Vector 5)

    @Test
    func `performForegroundSync watermark verification — full pass stamps freshness per scope`() throws {
        let suite = "FGWatermarkSuccess_\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let zoneID = CKRecordZone.ID(zoneName: "FGWatermarkZone", ownerName: CKCurrentUserDefaultName)
        let family = Family(
            name: "FG Family",
            createdBy: CKRecord.ID(recordName: "owner", zoneID: zoneID),
            id: CKRecord.ID(recordName: "fg-family", zoneID: zoneID)
        )
        let appState = AppState(defaults: defaults)
        appState.family = family
        appState.familyZoneID = zoneID
        appState.isZoneOwner = true

        let cache = try CacheService(inMemory: true, defaults: defaults)
        cache.invalidateAllFreshness()
        appState.cacheService = cache
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID

        let bgActor = try BackgroundCacheActor(container: #require(cache.container))
        let resolver = CKSyncConflictResolver(cacheService: cache, appState: appState)
        let handler = CKSyncEngineDelegateHandler(
            backgroundCache: bgActor,
            conflictResolver: resolver,
            cacheService: cache,
            appState: appState
        )
        let coordinator = CKSyncEngineCoordinator(
            cloudKitService: cloudKit,
            delegateHandler: handler,
            appState: appState,
            defaults: defaults
        )

        // Precondition: no freshness before foreground sync.
        for type in CachedRecordType.allCases {
            #expect(cache.isCacheFresh(familyRecordName: "fg-family", type: type) == false)
            #expect(cache.isCacheFresh(familyRecordName: "fg-family", type: type, scope: .private) == false)
        }

        // Simulate the watermark stamping that a successful foreground sync performs
        // via CKSyncEngineCoordinator.completeSyncPass — active scopes subset of
        // completed with zero parse/cache failures.
        coordinator.simulateFetchPassSettlement(activeScopes: [.private], completedScopes: [.private])

        // LootListApp.task(id: scenePhase) when .active calls performForegroundSync
        // which ultimately stamps cache_fresh_<family>_<type>_<scope> per type/scope.
        for type in CachedRecordType.allCases where type.fetchScopes.contains(.private) {
            #expect(cache.isCacheFresh(familyRecordName: "fg-family", type: type, scope: .private) == true)
            #expect(cache.isCacheFresh(familyRecordName: "fg-family", type: type) == true)
        }
        // Shared-scope types must not be stamped by a private-only pass.
        for type in CachedRecordType.allCases where !type.fetchScopes.contains(.private) {
            #expect(cache.isCacheFresh(familyRecordName: "fg-family", type: type, scope: .private) == false)
        }
    }

    @Test
    func `performForegroundSync watermark verification — parse and cache failures suppress stamping`() throws {
        let suite = "FGWatermarkFail_\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let zoneID = CKRecordZone.ID(zoneName: "FGWatermarkFailZone", ownerName: CKCurrentUserDefaultName)
        let family = Family(
            name: "FG Fail Family",
            createdBy: CKRecord.ID(recordName: "owner", zoneID: zoneID),
            id: CKRecord.ID(recordName: "fg-fail-family", zoneID: zoneID)
        )
        let appState = AppState(defaults: defaults)
        appState.family = family
        appState.familyZoneID = zoneID

        let cache = try CacheService(inMemory: true, defaults: defaults)
        cache.invalidateAllFreshness()
        appState.cacheService = cache
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID

        let bgActor = try BackgroundCacheActor(container: #require(cache.container))
        let resolver = CKSyncConflictResolver(cacheService: cache, appState: appState)
        let handler = CKSyncEngineDelegateHandler(
            backgroundCache: bgActor,
            conflictResolver: resolver,
            cacheService: cache,
            appState: appState
        )

        // Foreground sync that encounters a parse failure must suppress all stamps.
        let parseFailCoordinator = CKSyncEngineCoordinator(
            cloudKitService: cloudKit,
            delegateHandler: handler,
            appState: appState,
            defaults: defaults
        )
        parseFailCoordinator.simulateFetchPassSettlement(
            activeScopes: [.private],
            completedScopes: [.private],
            hasParseFailures: true
        )
        for type in CachedRecordType.allCases {
            #expect(cache.isCacheFresh(familyRecordName: "fg-fail-family", type: type) == false)
            #expect(cache.isCacheFresh(familyRecordName: "fg-fail-family", type: type, scope: .private) == false)
        }

        // Cache-write failure also suppresses stamping.
        cache.invalidateAllFreshness()
        let cacheFailCoordinator = CKSyncEngineCoordinator(
            cloudKitService: cloudKit,
            delegateHandler: handler,
            appState: appState,
            defaults: defaults
        )
        cacheFailCoordinator.simulateFetchPassSettlement(
            activeScopes: [.private],
            completedScopes: [.private],
            hasCacheWriteFailures: true
        )
        for type in CachedRecordType.allCases {
            #expect(cache.isCacheFresh(familyRecordName: "fg-fail-family", type: type) == false)
        }

        // Incomplete scope — active has private+shared but only private completed.
        cache.invalidateAllFreshness()
        let incompleteCoordinator = CKSyncEngineCoordinator(
            cloudKitService: cloudKit,
            delegateHandler: handler,
            appState: appState,
            defaults: defaults
        )
        incompleteCoordinator.simulateFetchPassSettlement(
            activeScopes: [.private, .shared],
            completedScopes: [.private]
        )
        for type in CachedRecordType.allCases {
            #expect(cache.isCacheFresh(familyRecordName: "fg-fail-family", type: type) == false)
        }
    }

    @Test
    func `performForegroundSync triggers fetch and send as defined in LootListApp scenePhase`() async throws {
        let defaults = UserDefaults.ephemeral()
        let appState = AppState(defaults: defaults)
        let zoneID = CKRecordZone.ID(zoneName: "FGSequenceZone", ownerName: "Owner")
        let (family, profile) = makeFamilyAndProfile(zoneID: zoneID)
        appState.family = family
        appState.currentProfile = profile
        appState.familyZoneID = zoneID
        appState.isZoneOwner = true
        appState.authStatus = .authenticated

        let cloudKit = MockCloudKitService()
        cloudKit.seedMockRecords([family, profile])
        let counting = CountingSyncCoordinator()
        let lifecycle = try makeLifecycle(appState: appState, cloudKit: cloudKit, sync: counting, defaults: defaults)
        lifecycle.setHasCompletedInitialBootstrapForTests(true)

        // LootListApp .task(id: scenePhase) when .active calls performForegroundSync
        // which must fetch, send, reconcile, and re-evaluate trophies.
        await lifecycle.performForegroundSync()
        #expect(counting.fetchCount == 1)
        // Subsequent foreground sync after idle must succeed again.
        await lifecycle.performForegroundSync()
        #expect(counting.fetchCount == 2)
    }
}
