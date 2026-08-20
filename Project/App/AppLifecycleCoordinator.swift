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
    /// Plain Bool guards on @MainActor are atomic only until the first await:
    /// once the task suspends, the actor yields and a second caller can observe
    /// the stale flag. Wrapping the flags in a `Mutex` makes check-and-set
    /// atomic via `withLock`, so foreground sync and remote notification cannot
    /// interleave at the first suspension point.
    private enum Phase: Equatable, Sendable {
        case idle
        case bootstrapping
        case syncing
        case zoneChanging
    }

    /// All mutable lifecycle flags are co-located in one `Mutex` so a single
    /// `withLock` can atomically test every guard that a caller cares about.
    /// `isManualSyncing` is tracked separately from `phase == .syncing` so a
    /// user-initiated manual sync is not starved while a foreground sync holds
    /// the syncing phase — the two sync paths use independent flags.
    private struct LifecycleFlags: Sendable {
        var phase: Phase = .idle
        var isManualSyncing = false
        var hasCompletedInitialBootstrap = false
        var lastSynchronizedScopeKey: String?
        var lastObservedZoneID: CKRecordZone.ID?
    }

    private let state = Mutex<LifecycleFlags>(LifecycleFlags())

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
    private let cloudKitService: any CloudKitServiceProtocol

    /// Injected scheduler so tests can simulate a failing `scheduleWeeklyPayoutRefresh`.
    private let payoutScheduler: (PayoutDay) -> Bool

    // Observer handles must be accessible from nonisolated deinit; MainActor-isolated
    // storage would be unreachable during deallocation on Swift 6's strict isolation.
    @ObservationIgnored private nonisolated(unsafe) var sessionClearObserver: NSObjectProtocol?
    @ObservationIgnored private nonisolated(unsafe) var zoneChangeObserver: NSObjectProtocol?

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
        // `resetState` on the sync coordinator clears engines, but without clearing
        // `lastSynchronizedScopeKey` a subsequent sign-in to a different family
        // whose scope string collides could skip `initializeEngines`.
        sessionClearObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("didClearSession"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.invalidateScopeStateForSessionClear()
            }
        }

        // Observe zone identity changes that occur without an engine reset so a
        // stale `lastSynchronizedScopeKey` does not make a new zone appear
        // already synchronized.
        zoneChangeObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("didChangeFamilyZoneID"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.invalidateScopeForZoneChange()
            }
        }
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

    deinit {
        if let observer = sessionClearObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = zoneChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
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
        }
        logger.info("Lifecycle scope state invalidated after session clear")
    }

    /// When `familyZoneID` changes without engine re-initialization the cached
    /// scope key must be discarded, otherwise a zone switch could appear already
    /// synchronized and skip `initializeEngines`.
    private func handleZoneChangeIfNeeded(currentZoneID: CKRecordZone.ID?) {
        state.withLock { flags in
            if flags.lastObservedZoneID != currentZoneID {
                if flags.lastSynchronizedScopeKey != nil {
                    logger.info("Family zone changed — invalidating cached scope key")
                    flags.lastSynchronizedScopeKey = nil
                }
                flags.lastObservedZoneID = currentZoneID
            }
        }
    }

    /// Handles zone changes delivered via `didChangeFamilyZoneID` without going
    /// through `initializeAndSyncActiveScope`, ensuring the scope cache is
    /// cleared even when the zone switches while engines remain initialized.
    private func invalidateScopeForZoneChange() {
        state.withLock { flags in
            if flags.lastSynchronizedScopeKey != nil {
                logger.info("Family zone changed (notification) — invalidating cached scope key")
                flags.lastSynchronizedScopeKey = nil
            }
            // Keep `lastObservedZoneID` in sync so the next
            // `handleZoneChangeIfNeeded` comparison does not double-clear.
            flags.lastObservedZoneID = appState?.familyZoneID
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
            // Manual sync is user-initiated and must not be starved by a
            // foreground sync holding `.syncing`. It is gated only on its own
            // flag and on bootstrap, so it can run concurrently with foreground
            // sync if the user explicitly requests it.
            guard flags.phase != .bootstrapping else { return false }
            guard !flags.isManualSyncing else { return false }
            flags.isManualSyncing = true
            return true
        }
    }

    private func tryEnterZoneChange() -> Bool {
        state.withLock { flags in
            guard flags.hasCompletedInitialBootstrap else { return false }
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

        await checkCloudKitAccountStatus()

        if let appState {
            await cloudKitService.processAbandonedZonesQueue(appState: appState)
        }

        await appState?.restoreSession(cloudKit: cloudKitService)

        guard await initializeAndSyncActiveScope() else {
            // Even when no authenticated scope is available the weekly payout
            // schedule must be attempted before marking bootstrap complete, so
            // hasCompletedInitialBootstrap never flips before the schedule call.
            let didSchedule = payoutScheduler(appState?.family?.payoutDay ?? .sunday)
            if didSchedule {
                state.withLock { $0.hasCompletedInitialBootstrap = true }
            }
            logger.info("Initial bootstrap paused without an authenticated family scope")
            return
        }

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
                return concrete.privateSyncEngine == nil || concrete.sharedSyncEngine == nil
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

        if let concrete = syncCoordinator as? CKSyncEngineCoordinator, concrete.syncError == nil {
            state.withLock { flags in
                flags.lastSynchronizedScopeKey = scopeKey
                flags.lastObservedZoneID = zoneID
            }
        } else if syncCoordinator is CKSyncEngineCoordinator == false {
            // Test doubles have no syncError — stamp on success.
            state.withLock { flags in
                flags.lastSynchronizedScopeKey = scopeKey
                flags.lastObservedZoneID = zoneID
            }
        }
        return true
    }

    private func checkCloudKitAccountStatus() async {
        guard !TestEnvironment.isRunningUnitOrUITests else { return }
        let container = CloudKitService.defaultContainer
        do {
            let status = try await container.accountStatus()
            switch status {
            case .available:
                break
            case .noAccount, .restricted, .couldNotDetermine, .temporarilyUnavailable:
                logger.warning("CloudKit account status is \(String(describing: status))")
            @unknown default:
                break
            }
        } catch {
            logger.error("CloudKit availability check failed: \(error, privacy: .private)")
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
        await syncCoordinator?.fetchChanges()
        await syncCoordinator?.sendPendingChanges()
        logger.info("Manual sync completed")
    }

    // MARK: - Family Zone Change

    /// Re-registers subscriptions and re-runs migrations/payouts when the
    /// active family zone changes. Guarded against in-flight and requires completed bootstrap.
    func performFamilyZoneChange() async {
        guard tryEnterZoneChange() else {
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
