//
//  AppLifecycleCoordinator.swift
//  LootList
//
//  Created by Ben Mackin on 8/17/26.
//

import CloudKit
import Foundation
import os
import Synchronization

// MARK: - CoordinatorState

/// Single-flight state machine for lifecycle coordination.
enum CoordinatorState: Equatable, Sendable {
    case idle
    case bootstrapping
    case syncing
    case zoneChanging
}

// MARK: - SyncCoordinating

/// Minimal surface `AppLifecycleCoordinator` needs from the sync engine.
@MainActor
protocol SyncCoordinating: AnyObject {
    func fetchChanges() async
    func sendPendingChanges() async
}

extension CKSyncEngineCoordinator: SyncCoordinating {}

// MARK: - AppLifecycleCoordinator

@MainActor
@Observable
final class AppLifecycleCoordinator {
    // MARK: - Logging

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "LootList",
        category: "AppLifecycleCoordinator"
    )

    // MARK: - Lifecycle State Machine

    /// Single-flight state machine protecting the coordinator's in-flight flags.
    private enum Phase: Equatable, Sendable {
        case idle
        case bootstrapping
        case syncing
        case zoneChanging
    }

    /// All mutable lifecycle flags are co-located in one `Mutex` so a single `withLock` can atomically test
    /// every guard that a caller cares about.
    private struct LifecycleFlags: Sendable {
        var phase: Phase = .idle
        var isManualSyncing = false
        var hasCompletedInitialBootstrap = false
        var lastSynchronizedScopeKey: String?
        var lastObservedZoneID: (zoneName: String, ownerName: String)?
        var lastReconnectTriggeredSyncAt: Date?
    }

    private let state = Mutex<LifecycleFlags>(LifecycleFlags())

    /// WHY: each reconnect-triggered sync runs a full multi-query CloudKit
    /// snapshot pass — connectivity flaps within this window coalesce into one.
    private static let reconnectSyncMinimumInterval: TimeInterval = 45

    // MARK: - Debug Overlay Exposure

    // WHY: Read-only debug overlay surface exposes Mutex-protected reconnect state
    // so push health can be correlated with debounce without exposing the Mutex itself;
    // interval references reconnectSyncMinimumInterval to avoid duplicating the 45s magic.

    /// Last time a reconnect-triggered sync was issued. Exposed read-only for
    /// the debug overlay so push health can be correlated with debounce state.
    var lastReconnectTriggeredSyncAtForDebug: Date? {
        state.withLock { $0.lastReconnectTriggeredSyncAt }
    }

    /// Debounce interval applied to reconnect-triggered syncs. Read-only for overlay.
    var reconnectDebounceIntervalForDebug: TimeInterval {
        Self.reconnectSyncMinimumInterval
    }

    // MARK: - Test Accessors

    /// Exposed for tests to assert the coordinator's current phase via the public enum.
    var coordinatorStateForTests: CoordinatorState {
        state.withLock { flags in
            switch flags.phase {
            case .idle: .idle
            case .bootstrapping: .bootstrapping
            case .syncing: .syncing
            case .zoneChanging: .zoneChanging
            }
        }
    }

    /// Test-only helper for atomic phase transitions.
    @discardableResult
    func transitionPhaseForTests(to newPhase: CoordinatorState) -> Bool {
        let target: Phase = switch newPhase {
        case .idle: .idle
        case .bootstrapping: .bootstrapping
        case .syncing: .syncing
        case .zoneChanging: .zoneChanging
        }
        return state.withLock { flags -> Bool in
            guard flags.phase == .idle else { return false }
            flags.phase = target
            return true
        }
    }

    /// Reset phase to idle for tests.
    func resetPhaseForTests() {
        state.withLock { $0.phase = .idle }
    }

    private weak var appState: AppState?
    private weak var syncCoordinator: (any SyncCoordinating)?
    private weak var appSyncCoordinator: AppSyncCoordinator?
    private weak var dataMigrationsCoordinator: DataMigrationsCoordinator?
    private weak var autoPayoutCoordinator: AutoPayoutCoordinator?
    var achievementService: AchievementService?
    private let cloudKitService: any CloudKitServiceProtocol

    /// Injected scheduler so tests can simulate a failing `scheduleWeeklyPayoutRefresh`.
    private let payoutScheduler: (PayoutDay) -> Bool

    @ObservationIgnored private var sessionClearTask: Task<Void, Never>?
    @ObservationIgnored private var zoneChangeTask: Task<Void, Never>?
    @ObservationIgnored private var networkReconnectTask: Task<Void, Never>?
    @ObservationIgnored private var accountChangeTask: Task<Void, Never>?

    // MARK: - Initialization

    init(
        appState: AppState,
        cloudKitService: any CloudKitServiceProtocol,
        syncCoordinator: any SyncCoordinating,
        appSyncCoordinator: AppSyncCoordinator,
        dataMigrationsCoordinator: DataMigrationsCoordinator,
        autoPayoutCoordinator: AutoPayoutCoordinator,
        payoutScheduler: ((PayoutDay) -> Bool)? = nil
    ) {
        self.appState = appState
        self.cloudKitService = cloudKitService
        self.syncCoordinator = syncCoordinator
        self.appSyncCoordinator = appSyncCoordinator
        self.dataMigrationsCoordinator = dataMigrationsCoordinator
        self.autoPayoutCoordinator = autoPayoutCoordinator
        self.payoutScheduler = payoutScheduler ?? { day in
            AppDelegate.scheduleWeeklyPayoutRefresh(payoutDay: day)
            return true
        }

        // Observe session clear so the cached scope key does not survive a sign-out.
        sessionClearTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .didClearSession) {
                guard !Task.isCancelled, let self else { break }
                self.invalidateScopeStateForSessionClear()
            }
        }

        // Observe zone identity changes that occur without an engine reset so a
        // stale `lastSynchronizedScopeKey` does not make a new zone appear
        // already synchronized.
        zoneChangeTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .didChangeFamilyZoneID) {
                guard !Task.isCancelled, let self else { break }
                self.invalidateScopeForZoneChange()
            }
        }

        // Trigger automatic catch-up sync when network connectivity returns.
        // Throttled: rapid reconnect flaps must not each fire a full snapshot pass.
        networkReconnectTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .networkDidReconnect) {
                guard !Task.isCancelled, let self else { break }
                let shouldSync: Bool = self.state.withLock { flags in
                    let last = flags.lastReconnectTriggeredSyncAt ?? .distantPast
                    guard Date().timeIntervalSince(last) >= Self.reconnectSyncMinimumInterval else {
                        return false
                    }
                    flags.lastReconnectTriggeredSyncAt = Date()
                    return true
                }
                guard shouldSync else {
                    self.logger
                        .debug(
                            "Reconnect sync throttled: last pass within \(Self.reconnectSyncMinimumInterval)s window"
                        )
                    continue
                }
                await self.performManualSync()
            }
        }

        accountChangeTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .CKAccountChanged) {
                guard !Task.isCancelled, let self, let appState = self.appState else { break }
                await appState.authStateMachine.send(.accountChanged)
            }
        }
    }

    deinit {
        sessionClearTask?.cancel()
        zoneChangeTask?.cancel()
        networkReconnectTask?.cancel()
        accountChangeTask?.cancel()
    }

    /// Convenience initializer preserving the existing `CKSyncEngineCoordinator` call site.
    convenience init(
        appState: AppState,
        cloudKitService: any CloudKitServiceProtocol,
        syncCoordinator: CKSyncEngineCoordinator,
        appSyncCoordinator: AppSyncCoordinator,
        dataMigrationsCoordinator: DataMigrationsCoordinator,
        autoPayoutCoordinator: AutoPayoutCoordinator
    ) {
        self.init(
            appState: appState,
            cloudKitService: cloudKitService,
            syncCoordinator: syncCoordinator as any SyncCoordinating,
            appSyncCoordinator: appSyncCoordinator,
            dataMigrationsCoordinator: dataMigrationsCoordinator,
            autoPayoutCoordinator: autoPayoutCoordinator,
            payoutScheduler: nil
        )
    }

    // MARK: - Scope Invalidation

    /// Clears the cached scope key and resets bootstrap completion so a
    /// post-sign-out sign-in cannot reuse a stale scope and skip engine init.
    private func invalidateScopeStateForSessionClear() {
        state.withLock { flags in
            flags.lastSynchronizedScopeKey = nil
            flags.hasCompletedInitialBootstrap = false
            flags.phase = .idle
            flags.isManualSyncing = false
            flags.lastObservedZoneID = nil
            flags.lastReconnectTriggeredSyncAt = nil
        }
        logger.info("Lifecycle scope state invalidated after session clear")
    }

    /// When `familyZoneID` changes without engine re-initialization the cached
    /// scope key must be discarded, otherwise a zone switch could appear already
    /// synchronized and skip `initializeEngines`.
    private func handleZoneChangeIfNeeded(currentZoneID: CKRecordZone.ID?) {
        let currentWrapped = currentZoneID.map {
            (zoneName: $0.zoneName, ownerName: $0.ownerName)
        }
        state.withLock { flags in
            let isSameZone = flags.lastObservedZoneID?.zoneName == currentWrapped?.zoneName
                && flags.lastObservedZoneID?.ownerName == currentWrapped?.ownerName
            if !isSameZone {
                if flags.lastSynchronizedScopeKey != nil {
                    logger.info("Family zone changed — invalidating cached scope key")
                    flags.lastSynchronizedScopeKey = nil
                }
                flags.lastObservedZoneID = currentWrapped
            }
        }
    }

    /// Handles zone changes delivered via `didChangeFamilyZoneID` without going
    /// through `initializeAndSyncActiveScope`, ensuring the scope cache is
    /// cleared even when the zone switches while engines remain initialized.
    private func invalidateScopeForZoneChange() {
        let wrapped = appState?.familyZoneID.map {
            (zoneName: $0.zoneName, ownerName: $0.ownerName)
        }
        state.withLock { flags in
            if flags.lastSynchronizedScopeKey != nil {
                logger.info("Family zone changed (notification) — invalidating cached scope key")
                flags.lastSynchronizedScopeKey = nil
            }
            // Keep `lastObservedZoneID` in sync so the next
            // `handleZoneChangeIfNeeded` comparison does not double-clear.
            flags.lastObservedZoneID = wrapped
        }
    }

    // MARK: - Atomic Single-Flight Helpers

    private func tryEnterBootstrap() -> Bool {
        state.withLock { flags in
            guard !flags.hasCompletedInitialBootstrap else { return false }
            guard flags.phase == .idle, !flags.isManualSyncing else { return false }
            flags.phase = .bootstrapping
            return true
        }
    }

    private func tryEnterSync() -> Bool {
        state.withLock { flags in
            guard flags.hasCompletedInitialBootstrap else { return false }
            guard flags.phase == .idle else { return false }
            flags.phase = .syncing
            return true
        }
    }

    private func tryEnterManualSync() -> Bool {
        state.withLock { flags in
            // Manual sync is user-initiated and must not be starved by a foreground sync holding `.syncing`.
            guard flags.phase != .bootstrapping else { return false }
            guard !flags.isManualSyncing else { return false }
            flags.isManualSyncing = true
            return true
        }
    }

    private func tryEnterZoneChange(allowBeforeBootstrap: Bool = false) -> Bool {
        state.withLock { flags in
            guard flags.hasCompletedInitialBootstrap || allowBeforeBootstrap else { return false }
            guard flags.phase == .idle, !flags.isManualSyncing else { return false }
            flags.phase = .zoneChanging
            return true
        }
    }

    private func exitPhase(_ phase: Phase) {
        state.withLock { flags in
            if flags.phase == phase {
                flags.phase = .idle
            }
        }
    }

    private func exitManualSync() {
        state.withLock { flags in
            flags.isManualSyncing = false
        }
    }

    private var hasCompletedInitialBootstrapSnapshot: Bool {
        state.withLock { $0.hasCompletedInitialBootstrap }
    }

    private var phaseSnapshot: Phase {
        state.withLock { $0.phase }
    }

    private var isManualSyncingSnapshot: Bool {
        state.withLock { $0.isManualSyncing }
    }

    /// Resets the scope cache when the active family zone is cleared or switched.
    /// Called internally on zone change and via the session-clear notification.
    func resetSynchronizedScope() {
        state.withLock { flags in
            flags.lastSynchronizedScopeKey = nil
            flags.lastObservedZoneID = nil
        }
    }

    // MARK: - Bootstrap

    /// Runs the full initial bootstrap sequence exactly once. Subsequent calls
    /// are no-ops while one is in flight or after the initial bootstrap completes.
    /// Call from the app root `.task` modifier only.
    func performInitialBootstrap() async {
        guard tryEnterBootstrap() else {
            let completed = state.withLock { $0.hasCompletedInitialBootstrap }
            let phase = state.withLock { $0.phase }
            logger.info("Bootstrap skipped: phase=\(String(describing: phase)), completed=\(completed)")
            return
        }
        defer {
            exitPhase(.bootstrapping)
        }

        logger.info("Starting initial bootstrap sequence")

        await refreshCloudAccountStatus()

        if let appState {
            await cloudKitService.processAbandonedZonesQueue(appState: appState)
        }

        await appState?.restoreSession(cloudKit: cloudKitService)

        // Initialize sync engines before any operation that may enqueue saves
        // (migrations, payouts, hero seeding) to avoid the nil-engine window.
        if let concrete = syncCoordinator as? CKSyncEngineCoordinator {
            concrete.initializeEngines()
        }

        guard await initializeAndSyncActiveScope() else {
            // Keep bootstrap incomplete without an authenticated family. A
            // recovered session can complete it through the zone-change path.
            let didSchedule = payoutScheduler(appState?.family?.payoutDay ?? .sunday)
            if !didSchedule {
                logger.warning("Bootstrap scheduler failed without an authenticated family scope")
            }
            logger.info("Initial bootstrap paused without an authenticated family scope")
            return
        }

        await reconcileCacheFromCloudKit()

        if let zoneID = appState?.familyZoneID {
            let db = cloudKitService.database(isOwner: appState?.isZoneOwner ?? false)
            await appSyncCoordinator?.registerSubscriptions(for: zoneID, in: db)
        }

        if let accountID = appState?.currentProfile?.id.recordName ?? appState?.family?.id.recordName,
           let familyRecordName = appState?.family?.id.recordName
        {
            await dataMigrationsCoordinator?.runPendingMigrations(
                accountID: accountID,
                familyRecordName: familyRecordName
            )
        }

        // 7. Payout processing — schedule must succeed before marking bootstrap complete.
        await autoPayoutCoordinator?.processPendingPayoutsIfDue()
        let didSchedule = payoutScheduler(appState?.family?.payoutDay ?? .sunday)
        guard didSchedule else {
            logger.warning("Bootstrap not marked completed: payout scheduler failed")
            return
        }

        await evaluateTrophiesCatchup()

        state.withLock { $0.hasCompletedInitialBootstrap = true }
        logger.info("Initial bootstrap sequence completed successfully")
    }

    private func initializeAndSyncActiveScope() async -> Bool {
        guard let appState,
              appState.authStatus == .authenticated,
              let family = appState.family,
              let profile = appState.currentProfile,
              let zoneID = appState.familyZoneID,
              family.id.zoneID == zoneID,
              profile.id.zoneID == zoneID,
              profile.family.recordID == family.id,
              let syncCoordinator
        else {
            return false
        }

        handleZoneChangeIfNeeded(currentZoneID: zoneID)

        let scopeKey = "\(profile.id.recordName)|\(family.id.recordName)|\(zoneID.zoneName)|\(zoneID.ownerName)|\(appState.isZoneOwner)"
        let enginesNeedInitialization: Bool = {
            if let concrete = syncCoordinator as? CKSyncEngineCoordinator {
                return concrete.activeEngine(isOwner: appState.isZoneOwner) == nil
            }
            return false
        }()
        let shouldInitialize: Bool = state.withLock { flags in
            guard flags.lastSynchronizedScopeKey != scopeKey || enginesNeedInitialization else {
                return false
            }
            return true
        }
        guard shouldInitialize else {
            return true
        }

        await syncCoordinator.fetchChanges()
        await syncCoordinator.sendPendingChanges()
        await reconcileCacheFromCloudKit()
        await evaluateTrophiesCatchup()

        let wrappedZoneID = (zoneName: zoneID.zoneName, ownerName: zoneID.ownerName)
        if let concrete = syncCoordinator as? CKSyncEngineCoordinator, concrete.syncError == nil {
            state.withLock { flags in
                flags.lastSynchronizedScopeKey = scopeKey
                flags.lastObservedZoneID = wrappedZoneID
            }
        } else if syncCoordinator is CKSyncEngineCoordinator == false {
            // Test doubles have no syncError — stamp on success.
            state.withLock { flags in
                flags.lastSynchronizedScopeKey = scopeKey
                flags.lastObservedZoneID = wrappedZoneID
            }
        }
        return true
    }

    private struct FamilySnapshot {
        let inboundRecords: [CKRecord]
        let validRecordNamesByType: [CachedRecordType: Set<String>]
        let isEmpty: Bool
    }

    private func fetchSnapshotRecords(
        _ type: (some CloudKitRecord).Type,
        predicate: NSPredicate,
        zoneID: CKRecordZone.ID,
        db: CKDatabase?
    ) async throws -> ([CKRecord], Set<String>) {
        let models = try await cloudKitService.query(type, predicate: predicate, in: zoneID, sortDescriptors: nil, using: db)
        let records = models.map { $0.toRecord() }
        let names = Set(records.map(\.recordID.recordName))
        return (records, names)
    }

    private func fetchFamilySnapshot(family: Family, zoneID: CKRecordZone.ID, isOwner: Bool) async throws -> FamilySnapshot {
        let db = isOwner ? cloudKitService.privateDatabase : cloudKitService.sharedDatabase
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let familyPredicate = NSPredicate(format: "family == %@", familyRef)
        let idPredicate = NSPredicate(format: "recordID == %@", family.id)

        let (quests, questNames) = try await fetchSnapshotRecords(Quest.self, predicate: familyPredicate, zoneID: zoneID, db: db)
        let (entries, entryNames) = try await fetchSnapshotRecords(LedgerEntry.self, predicate: familyPredicate, zoneID: zoneID, db: db)
        let (completions, completionNames) = try await fetchSnapshotRecords(QuestCompletion.self, predicate: familyPredicate, zoneID: zoneID, db: db)
        let (periods, periodNames) = try await fetchSnapshotRecords(AllowancePeriod.self, predicate: familyPredicate, zoneID: zoneID, db: db)
        let (goals, goalNames) = try await fetchSnapshotRecords(Goal.self, predicate: familyPredicate, zoneID: zoneID, db: db)
        let (profiles, profileNames) = try await fetchSnapshotRecords(Profile.self, predicate: familyPredicate, zoneID: zoneID, db: db)
        let (templates, templateNames) = try await fetchSnapshotRecords(QuestTemplate.self, predicate: familyPredicate, zoneID: zoneID, db: db)
        let (families, familyNames) = try await fetchSnapshotRecords(Family.self, predicate: idPredicate, zoneID: zoneID, db: db)
        let (achievements, achievementNames) = try await fetchSnapshotRecords(Achievement.self, predicate: familyPredicate, zoneID: zoneID, db: db)
        let (profileAchievements, profileAchievementNames) = try await fetchSnapshotRecords(ProfileAchievement.self, predicate: familyPredicate, zoneID: zoneID, db: db)
        let (notifPrefs, notifPrefNames) = try await fetchSnapshotRecords(NotificationPreference.self, predicate: familyPredicate, zoneID: zoneID, db: db)
        let (gemLedgers, gemLedgerNames) = try await fetchSnapshotRecords(GemLedger.self, predicate: familyPredicate, zoneID: zoneID, db: db)
        let (rewardEvents, rewardEventNames) = try await fetchSnapshotRecords(RewardEvent.self, predicate: familyPredicate, zoneID: zoneID, db: db)

        let inboundRecords = quests + entries + completions + periods + goals + profiles
            + templates + families + achievements + profileAchievements + notifPrefs + gemLedgers + rewardEvents

        let validRecordNamesByType: [CachedRecordType: Set<String>] = [
            .quest: questNames,
            .ledgerEntry: entryNames,
            .questCompletion: completionNames,
            .allowancePeriod: periodNames,
            .goal: goalNames,
            .profile: profileNames,
            .questTemplate: templateNames,
            .family: familyNames,
            .achievement: achievementNames,
            .profileAchievement: profileAchievementNames,
            .notificationPreference: notifPrefNames,
            .gemLedger: gemLedgerNames,
            .rewardEvent: rewardEventNames
        ]

        let isEmpty = validRecordNamesByType.values.allSatisfy(\.isEmpty)

        return FamilySnapshot(
            inboundRecords: inboundRecords,
            validRecordNamesByType: validRecordNamesByType,
            isEmpty: isEmpty
        )
    }

    private func reconcileCacheFromCloudKit() async {
        guard let appState,
              let family = appState.family,
              let zoneID = appState.familyZoneID
        else {
            return
        }

        let isOwner = appState.isZoneOwner
        do {
            let snapshot = try await fetchFamilySnapshot(family: family, zoneID: zoneID, isOwner: isOwner)

            guard !snapshot.isEmpty else {
                logger.warning(
                    "Cache reconciliation aborted: empty snapshot — pruning skipped to preserve pending rows",
                    family: family.id.recordName,
                    zone: zoneID.zoneName
                )
                return
            }

            if !isOwner, let backgroundCache = appState.backgroundCacheActor {
                guard let outcome = await backgroundCache.reconcileParticipantSet(
                    records: snapshot.inboundRecords,
                    validRecordNamesByType: snapshot.validRecordNamesByType,
                    familyRecordName: family.id.recordName,
                    databaseScope: .shared,
                    zoneID: zoneID
                )
                else { return }

                if !outcome.commitSucceeded {
                    logger.error(
                        "Participant cache reconciliation commit failed; \(outcome.recordCount) record(s) left for the next pass",
                        family: family.id.recordName,
                        zone: zoneID.zoneName
                    )
                } else if outcome.parseFailures > 0 {
                    logger.warning(
                        "Participant cache reconciliation dropped \(outcome.parseFailures) unparseable record(s)",
                        family: family.id.recordName,
                        zone: zoneID.zoneName
                    )
                }
            } else if let concrete = syncCoordinator as? CKSyncEngineCoordinator {
                await concrete.delegateHandler.handleIncomingRecordsDirectly(
                    snapshot.inboundRecords,
                    databaseScope: .private,
                    zoneID: zoneID
                )
            } else if let backgroundCache = appState.backgroundCacheActor {
                let parsed = snapshot.inboundRecords.map { ParsedRecord.parse(record: $0) }
                await backgroundCache.batchUpsertParsedRecords(parsed)
            }
            // Track push age for debug overlay — completion of the snapshot
            // reconciliation pass represents a successful push-driven refresh.
            if let concrete = syncCoordinator as? CKSyncEngineCoordinator {
                concrete.notePushReceived()
            }
        } catch {
            logger.error(
                "Cache reconciliation failed: \(error)",
                family: family.id.recordName,
                zone: zoneID.zoneName
            )
        }
    }

    /// Refreshes the iCloud account status and publishes the CK-free mirror onto
    /// `appState.cloudAccountStatus`.
    @discardableResult
    func refreshCloudAccountStatus() async -> Bool {
        guard !TestEnvironment.isRunningUnitOrUITests else { return false }
        do {
            let status = try await CloudKitService.defaultContainer.accountStatus()
            appState?.cloudAccountStatus = CloudAccountStatus(status)
            switch status {
            case .available:
                break
            case .noAccount, .restricted, .couldNotDetermine, .temporarilyUnavailable:
                logger.warning("CloudKit account status is \(String(describing: status))")
            @unknown default:
                break
            }
            return true
        } catch {
            logger.error("CloudKit availability check failed: \(error, privacy: .private)")
            return false
        }
    }

    private func evaluateTrophiesCatchup() async {
        guard let appState, let profile = appState.currentProfile, let family = appState.family, let achievementService else { return }
        do {
            let awarded = try await achievementService.evaluateAll(for: profile, family: family)
            if !awarded.isEmpty {
                logger.info("Trophy catchup awarded \(awarded.count, privacy: .public) trophies: \(awarded.map(\.name).joined(separator: ", "), privacy: .public)")
            }
        } catch {
            logger.warning("Trophy catchup evaluation failed: \(error, privacy: .private)")
        }
    }

    // MARK: - Foreground and Manual Sync

    /// Lightweight re-sync for scene activation.
    func performForegroundSync() async {
        guard tryEnterSync() else {
            let completed = state.withLock { $0.hasCompletedInitialBootstrap }
            let phase = state.withLock { $0.phase }
            logger.info("Foreground sync skipped: completed=\(completed), phase=\(String(describing: phase))")
            return
        }
        defer { exitPhase(.syncing) }

        logger.info("Starting foreground sync")
        await syncCoordinator?.fetchChanges()
        await syncCoordinator?.sendPendingChanges()
        await reconcileCacheFromCloudKit()
        await evaluateTrophiesCatchup()
        logger.info("Foreground sync completed")
    }

    // MARK: - Manual Sync

    /// User-initiated manual sync.
    func performManualSync() async {
        guard tryEnterManualSync() else {
            let phase = state.withLock { $0.phase }
            let manual = state.withLock { $0.isManualSyncing }
            logger.info("Manual sync skipped: phase=\(String(describing: phase)), manualSyncing=\(manual)")
            return
        }
        defer { exitManualSync() }

        logger.info("Starting manual sync")
        if let concrete = syncCoordinator as? CKSyncEngineCoordinator,
           concrete.privateSyncEngine == nil, concrete.sharedSyncEngine == nil
        {
            concrete.initializeEngines()
        }
        await syncCoordinator?.fetchChanges()
        await syncCoordinator?.sendPendingChanges()
        await reconcileCacheFromCloudKit()
        await evaluateTrophiesCatchup()
        logger.info("Manual sync completed")
    }

    // MARK: - Family Zone Change

    /// Re-registers subscriptions and re-runs migrations/payouts when the
    /// active family zone changes. Recovered authenticated sessions may complete
    /// this transition before initial bootstrap has been marked complete.
    func performFamilyZoneChange() async {
        let bootstrapIncomplete = !state.withLock { $0.hasCompletedInitialBootstrap }
        // Hero recovery path: initial bootstrap paused at `detectedPreviousFamily` before authentication — the
        // subsequent `acceptDetectedFamily` sets `familyZoneID`/`.authenticated`.
        if bootstrapIncomplete {
            guard let appState,
                  appState.authStatus == .authenticated,
                  appState.family != nil,
                  appState.currentProfile != nil,
                  appState.familyZoneID != nil
            else {
                logger.info("Family zone change skipped: bootstrap not completed")
                return
            }
        }
        guard tryEnterZoneChange(allowBeforeBootstrap: bootstrapIncomplete) else {
            let completed = state.withLock { $0.hasCompletedInitialBootstrap }
            let phase = state.withLock { $0.phase }
            logger.info("Family zone change skipped: completed=\(completed), phase=\(String(describing: phase))")
            return
        }
        defer { exitPhase(.zoneChanging) }

        guard let appState,
              appState.authStatus == .authenticated,
              let zoneID = appState.familyZoneID,
              appState.family != nil,
              appState.currentProfile != nil,
              await initializeAndSyncActiveScope()
        else {
            return
        }

        await reconcileCacheFromCloudKit()

        let db = cloudKitService.database(isOwner: appState.isZoneOwner)
        await appSyncCoordinator?.registerSubscriptions(for: zoneID, in: db)

        if let accountID = appState.currentProfile?.id.recordName ?? appState.family?.id.recordName,
           let familyRecordName = appState.family?.id.recordName
        {
            await dataMigrationsCoordinator?.runPendingMigrations(
                accountID: accountID,
                familyRecordName: familyRecordName
            )
        }

        await autoPayoutCoordinator?.processPendingPayoutsIfDue()
        _ = payoutScheduler(appState.family?.payoutDay ?? .sunday)

        // If this zone change completed the hero-recovery bootstrap, mark it done
        // so subsequent foreground/remote syncs are not permanently skipped.
        if !state.withLock({ $0.hasCompletedInitialBootstrap }) {
            state.withLock { $0.hasCompletedInitialBootstrap = true }
            logger.info("Family zone change completed initial bootstrap for recovered hero")
        }
    }

    // MARK: - Remote Notification

    /// Handles incoming remote push notification sync triggers.
    func handleRemoteNotification() async {
        guard tryEnterSync() else {
            let completed = state.withLock { $0.hasCompletedInitialBootstrap }
            let phase = state.withLock { $0.phase }
            logger.info("Remote sync skipped: completed=\(completed), phase=\(String(describing: phase))")
            return
        }
        defer { exitPhase(.syncing) }

        await syncCoordinator?.fetchChanges()
        await syncCoordinator?.sendPendingChanges()
        await reconcileCacheFromCloudKit()
    }

    // MARK: - Background Tasks

    /// Centralized background task handler for weekly payout refresh.
    func handleWeeklyPayoutBackgroundRefresh() async -> Bool {
        await autoPayoutCoordinator?.processPendingPayoutsIfDue()
        let payoutDay = appState?.family?.payoutDay ?? .sunday
        _ = payoutScheduler(payoutDay)
        return true
    }

    // MARK: - Test Helpers

    /// Test-only helper to set scope key directly.
    func setLastSynchronizedScopeKeyForTests(_ key: String?) {
        state.withLock { $0.lastSynchronizedScopeKey = key }
    }

    func setHasCompletedInitialBootstrapForTests(_ value: Bool) {
        state.withLock { $0.hasCompletedInitialBootstrap = value }
    }

    var isManualSyncingForTests: Bool {
        state.withLock { $0.isManualSyncing }
    }

    var lastSynchronizedScopeKey: String? {
        state.withLock { $0.lastSynchronizedScopeKey }
    }

    var hasCompletedInitialBootstrap: Bool {
        state.withLock { $0.hasCompletedInitialBootstrap }
    }
}

private extension Logger {
    func warning(_ message: String, family: String, zone: String) {
        log(level: .default, "\(message, privacy: .public) family=\(family, privacy: .private) zone=\(zone, privacy: .private)")
    }

    func info(_ message: String, family: String, zone: String) {
        log(level: .info, "\(message, privacy: .public) family=\(family, privacy: .private) zone=\(zone, privacy: .private)")
    }

    func error(_ message: String, family: String, zone: String) {
        log(level: .error, "\(message, privacy: .public) family=\(family, privacy: .private) zone=\(zone, privacy: .private)")
    }
}
