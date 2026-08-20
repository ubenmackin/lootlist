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
    payoutScheduler: ((PayoutDay) -> Bool)? = nil
) throws -> AppLifecycleCoordinator {
    let cache = try CacheService(inMemory: true)
    appState.cacheService = cache
    let appSync = AppSyncCoordinator()
    let defaults = UserDefaults.standard
    let migrations = DataMigrationsCoordinator(defaults: defaults)
    let toast = ToastManager()
    let notification = NotificationService(cloudKit: cloudKit, appState: appState, cacheService: cache)
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
        let appState = AppState()
        let cloudKit = MockCloudKitService()
        let sync = CountingSyncCoordinator()
        let lifecycle = try makeLifecycle(appState: appState, cloudKit: cloudKit, sync: sync)

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
        let appState = AppState()
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
        let lifecycle = try makeLifecycle(appState: appState, cloudKit: cloudKit, sync: gated)
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
        let lifecycle2 = try makeLifecycle(appState: appState, cloudKit: cloudKit, sync: counting)
        lifecycle2.setHasCompletedInitialBootstrapForTests(true)
        await lifecycle2.handleRemoteNotification()
        #expect(counting.fetchCount == 1)
    }

    // MARK: Manual Sync Independent Guard

    @Test
    func `performManualSync uses independent isManualSyncing and is not starved by foreground sync`() async throws {
        let appState = AppState()
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
        let lifecycle = try makeLifecycle(appState: appState, cloudKit: cloudKit, sync: gated)
        lifecycle.setHasCompletedInitialBootstrapForTests(true)

        let fgTask = Task { await lifecycle.performForegroundSync() }
        await gated.waitForParked(count: 1)
        #expect(lifecycle.coordinatorStateForTests == .syncing)

        // Manual sync must not be blocked by the syncing state — it uses its
        // own `isManualSyncing` mutex, so it should enter even while foreground is parked.
        let manualCounting = CountingSyncCoordinator()
        // Use a separate coordinator for the manual call to isolate fetch counting
        // while still proving the guard is independent: a second lifecycle sharing
        // the same manual mutex state would still allow entry. Instead we directly
        // verify the mutex is independent by checking `isManualSyncing` remains false
        // until manual starts and foreground state does not affect it.
        #expect(lifecycle.isManualSyncingForTests == false)

        // Park foreground, then attempt manual on same lifecycle — should still run.
        // We use a second gated coordinator to observe manual execution without
        // conflating counts: swap sync is not possible mid-flight, so verify via
        // mutex independence and then execute manual after releasing foreground.
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
        let lifecycle3 = try makeLifecycle(appState: appState, cloudKit: cloudKit, sync: gated2)
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

        _ = manualCounting
    }

    // MARK: lastSynchronizedScopeKey Mutex

    @Test
    func `lastSynchronizedScopeKey is Mutex-protected and cleared on session and zone change`() async throws {
        let appState = AppState()
        let cloudKit = MockCloudKitService()
        let sync = CountingSyncCoordinator()
        let lifecycle = try makeLifecycle(appState: appState, cloudKit: cloudKit, sync: sync)

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
        let appState = AppState()
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
        let lifecycle = try makeLifecycle(appState: appState, cloudKit: cloudKit, sync: gated)
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
        let lifecycle2 = try makeLifecycle(appState: appState, cloudKit: cloudKit, sync: counting)
        lifecycle2.setHasCompletedInitialBootstrapForTests(true)
        await lifecycle2.performForegroundSync()
        #expect(counting.fetchCount == 1)
    }

    // MARK: Existing Behavior Preserved

    @Test
    func `performInitialBootstrap runs only once and sets completed flag`() async throws {
        let suite = "AppLifecycle_Bootstrap_\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

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

        let cache = try CacheService(inMemory: true)
        appState.cacheService = cache

        let appSync = AppSyncCoordinator()
        let migrations = DataMigrationsCoordinator(defaults: defaults)
        var migrationRunCount = 0
        migrations.register(DataMigrationsCoordinator.MigrationStep(id: "TestStep", version: 1) { migrationRunCount += 1 })

        let toast = ToastManager()
        let notification = NotificationService(cloudKit: cloudKit, appState: appState, cacheService: cache)
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

        defaults.removePersistentDomain(forName: suite)
    }

    @Test
    func `performForegroundSync is lightweight and handles in-flight guards`() async throws {
        let appState = AppState()
        let cloudKit = MockCloudKitService()
        let sync = CountingSyncCoordinator()
        let lifecycle = try makeLifecycle(appState: appState, cloudKit: cloudKit, sync: sync)

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
        let suite = "AppLifecycle_ZoneChange_\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

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
        let cache = try CacheService(inMemory: true)
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
        let notification = NotificationService(cloudKit: cloudKit, appState: appState, cacheService: cache)
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

        defaults.removePersistentDomain(forName: suite)
    }
}
