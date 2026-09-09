//
//  AppLifecycleCoordinator.swift
//  LootList
//
//  Created by Ben Mackin on 8/17/26.
//

import CloudKit
import Foundation
import os

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

/// Centralized sync/payout/migration trigger — single-flight state machine.
@MainActor
@Observable
final class AppLifecycleCoordinator {
    // MARK: - Logging

    let logger = Logger(category: "AppLifecycleCoordinator")

    // MARK: - Lifecycle State Machine

    /// Single-flight state machine protecting the coordinator's in-flight flags.
    enum Phase: Equatable, Sendable {
        case idle
        case bootstrapping
        case syncing
        case zoneChanging
    }

    struct ZoneObservation: Equatable, Sendable {
        let didChange: Bool
        let previousZoneName: String?
        let previousOwnerName: String?
    }

    // WHY: Single-flight state lives in one gate so concurrent triggers collapse instead of interleaving.
    @MainActor
    final class LifecycleSyncGate {
        var phase: Phase = .idle
        var isManualSyncing = false
        var hasCompletedInitialBootstrap = false
        var lastSynchronizedScopeKey: String?
        var lastObservedZoneName: String?
        var lastObservedOwnerName: String?
        var lastReconnectTriggeredSyncAt: Date?
        var lastUnsyncedEnqueueAt: Date?

        func tryEnterBootstrap() -> Bool {
            guard phase == .idle, !hasCompletedInitialBootstrap else { return false }
            phase = .bootstrapping
            return true
        }

        func tryEnterSync() -> Bool {
            guard hasCompletedInitialBootstrap, phase == .idle else { return false }
            phase = .syncing
            return true
        }

        func tryEnterManualSync() -> Bool {
            // Manual sync is user-initiated and must not be starved by a foreground sync holding `.syncing`.
            guard phase != .bootstrapping else { return false }
            guard !isManualSyncing else { return false }
            isManualSyncing = true
            return true
        }

        func tryEnterZoneChange(allowBeforeBootstrap: Bool = false) -> Bool {
            guard hasCompletedInitialBootstrap || allowBeforeBootstrap, phase == .idle else { return false }
            phase = .zoneChanging
            return true
        }

        func exitPhase(_ expected: Phase) {
            guard phase == expected else { return }
            phase = .idle
        }

        func exitManualSync() {
            isManualSyncing = false
        }

        func markBootstrapComplete() {
            hasCompletedInitialBootstrap = true
        }

        func setSynchronizedScope(key: String, zoneName: String, ownerName: String) {
            lastSynchronizedScopeKey = key
            lastObservedZoneName = zoneName
            lastObservedOwnerName = ownerName
        }

        func shouldPerformReconciliation(scopeKey: String) -> Bool {
            lastSynchronizedScopeKey != scopeKey
        }

        func recordSynchronizedScope(scopeKey: String) {
            lastSynchronizedScopeKey = scopeKey
        }

        func invalidateForSessionClear() {
            lastSynchronizedScopeKey = nil
            lastObservedZoneName = nil
            lastObservedOwnerName = nil
            hasCompletedInitialBootstrap = false
        }

        func invalidateForZoneChange() {
            lastSynchronizedScopeKey = nil
            lastObservedZoneName = nil
            lastObservedOwnerName = nil
        }

        func resetForSignOut() {
            phase = .idle
            isManualSyncing = false
            hasCompletedInitialBootstrap = false
            lastSynchronizedScopeKey = nil
            lastObservedZoneName = nil
            lastObservedOwnerName = nil
        }

        func observeZone(zoneName: String, ownerName: String) -> ZoneObservation {
            guard let lastName = lastObservedZoneName, let lastOwner = lastObservedOwnerName else {
                lastObservedZoneName = zoneName
                lastObservedOwnerName = ownerName
                return ZoneObservation(didChange: false, previousZoneName: nil, previousOwnerName: nil)
            }
            if lastName != zoneName || lastOwner != ownerName {
                lastSynchronizedScopeKey = nil
                lastObservedZoneName = zoneName
                lastObservedOwnerName = ownerName
                return ZoneObservation(didChange: true, previousZoneName: lastName, previousOwnerName: lastOwner)
            }
            return ZoneObservation(didChange: false, previousZoneName: nil, previousOwnerName: nil)
        }

        func consumeReconnectTrigger(now: Date = Date()) -> Bool {
            let last = lastReconnectTriggeredSyncAt ?? .distantPast
            guard now.timeIntervalSince(last) >= AppLifecycleCoordinator.reconnectSyncMinimumInterval else {
                return false
            }
            lastReconnectTriggeredSyncAt = now
            return true
        }

        func consumeUnsyncedTrigger(now: Date = Date()) -> Bool {
            let last = lastUnsyncedEnqueueAt ?? .distantPast
            guard now.timeIntervalSince(last) >= AppLifecycleCoordinator.unsyncedEnqueueDebounceInterval else {
                return false
            }
            lastUnsyncedEnqueueAt = now
            return true
        }
    }

    let syncGate = LifecycleSyncGate()

    static let reconnectSyncMinimumInterval: TimeInterval = 45
    static let unsyncedEnqueueDebounceInterval: TimeInterval = 30

    // MARK: - Debug Overlay Exposure

    /// Last time a reconnect-triggered sync was issued. Exposed read-only for
    /// the debug overlay so push health can be correlated with debounce state.
    var lastReconnectTriggeredSyncAtForDebug: Date? {
        syncGate.lastReconnectTriggeredSyncAt
    }

    /// Debounce interval applied to reconnect-triggered syncs. Read-only for overlay.
    var reconnectDebounceIntervalForDebug: TimeInterval {
        Self.reconnectSyncMinimumInterval
    }

    // MARK: - Test Accessors

    /// Exposed for tests to assert the coordinator's current phase via the public enum.
    var coordinatorStateForTests: CoordinatorState {
        switch syncGate.phase {
        case .idle: .idle
        case .bootstrapping: .bootstrapping
        case .syncing: .syncing
        case .zoneChanging: .zoneChanging
        }
    }

    /// Exposed for tests to assert the coordinator's current phase directly.
    var phaseForTests: Phase {
        syncGate.phase
    }

    /// Injected references
    weak var appState: AppState?
    let cloudKitService: any CloudKitServiceProtocol
    let syncCoordinator: (any SyncCoordinating)?
    let appSyncCoordinator: AppSyncCoordinator?
    let dataMigrationsCoordinator: DataMigrationsCoordinator?
    let autoPayoutCoordinator: AutoPayoutCoordinator?
    var achievementService: AchievementService?

    /// Injected scheduler so tests can simulate a failing `scheduleWeeklyPayoutRefresh`.
    let payoutScheduler: (PayoutDay) -> Bool

    @ObservationIgnored private var sessionClearTask: Task<Void, Never>?
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
                // WHY hop: notification sequence resumes off isolation, so re-enter MainActor before touching gate state.
                await MainActor.run {
                    self.invalidateScopeStateForSessionClear()
                }
            }
        }

        // Typed zone-change observation replaces the former `didChangeFamilyZoneID`
        // NotificationCenter channel. `AppState` bumps `familyZoneIDChangeSignal`
        // and invokes `onFamilyZoneIDChange` directly, so no stringly-typed
        // notification is needed and ordering is tied to the `@Observable` state
        // model (§4).
        appState.onFamilyZoneIDChange = { [weak self] in
            self?.invalidateScopeForZoneChange()
        }

        // Trigger automatic catch-up sync when network connectivity returns.
        // Throttled: rapid reconnect flaps must not each fire a full snapshot pass.
        networkReconnectTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .networkDidReconnect) {
                guard !Task.isCancelled, let self else { break }
                // WHY hop: notification sequence resumes off isolation, so re-enter MainActor before touching gate state.
                let shouldSync: Bool = await MainActor.run {
                    self.syncGate.consumeReconnectTrigger()
                }
                guard shouldSync else {
                    await MainActor.run {
                        self.logger
                            .debug(
                                "Reconnect sync throttled: last pass within \(Self.reconnectSyncMinimumInterval)s window"
                            )
                    }
                    continue
                }
                await self.performManualSync()
            }
        }

        accountChangeTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .CKAccountChanged) {
                guard !Task.isCancelled, let self, let appState = self.appState else { break }
                // WHY hop: notification sequence resumes off isolation, so re-enter MainActor before touching auth state.
                await appState.authStateMachine.send(.accountChanged)
            }
        }
    }

    deinit {
        sessionClearTask?.cancel()
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
    func invalidateScopeStateForSessionClear() {
        syncGate.invalidateForSessionClear()
        logger.info("Cleared cached scope key and reset bootstrap completion for session clear")
    }

    /// Clears the cached scope key while keeping bootstrap completion intact
    /// when the active family zone changes mid-session.
    func invalidateScopeForZoneChange() {
        syncGate.invalidateForZoneChange()
        logger.info("Cleared cached scope key for zone change")
    }

    /// Detects in-process zone changes that occurred without triggering the
    /// `didChangeFamilyZoneID` notification.
    func handleZoneChangeIfNeeded(currentZoneID: CKRecordZone.ID) {
        let outcome = syncGate.observeZone(zoneName: currentZoneID.zoneName, ownerName: currentZoneID.ownerName)
        if outcome.didChange, let prevName = outcome.previousZoneName, let prevOwner = outcome.previousOwnerName {
            logger.info(
                "Zone ID changed in-process: (\(prevName), \(prevOwner)) -> (\(currentZoneID.zoneName), \(currentZoneID.ownerName))"
            )
        }
    }

    // MARK: - Atomic Single-Flight Helpers

    func tryEnterBootstrap() -> Bool {
        syncGate.tryEnterBootstrap()
    }

    func tryEnterSync() -> Bool {
        syncGate.tryEnterSync()
    }

    func tryEnterManualSync() -> Bool {
        syncGate.tryEnterManualSync()
    }

    func tryEnterZoneChange(allowBeforeBootstrap: Bool = false) -> Bool {
        syncGate.tryEnterZoneChange(allowBeforeBootstrap: allowBeforeBootstrap)
    }

    func exitPhase(_ phase: Phase) {
        syncGate.exitPhase(phase)
    }

    func exitManualSync() {
        syncGate.exitManualSync()
    }

    func forceResetPhaseForSignOut() {
        syncGate.resetForSignOut()
    }

    // MARK: - Terminated Sync Retry

    /// Schedules the BGProcessingTask retry for pending uploads.
    /// WHY: terminated-push coverage complements push-driven sync — silent
    /// pushes may be throttled on expensive networks and iOS 26 jetsam can
    /// kill the app before pendingRecordZoneChanges (ledger entries, quest
    /// completions) upload. The BGProcessingTask ensures unsynced changes
    /// eventually reach CloudKit when the system next launches the app.
    func scheduleTerminatedSyncRetry() {
        AppDelegate.scheduleSyncProcessingTask()
    }

    // MARK: - Test Helpers

    /// Test-only helper to set scope key directly.
    func setLastSynchronizedScopeKeyForTests(_ key: String?) {
        syncGate.lastSynchronizedScopeKey = key
    }

    func setHasCompletedInitialBootstrapForTests(_ value: Bool) {
        syncGate.hasCompletedInitialBootstrap = value
    }

    var isManualSyncingForTests: Bool {
        syncGate.isManualSyncing
    }

    var lastSynchronizedScopeKey: String? {
        syncGate.lastSynchronizedScopeKey
    }

    var hasCompletedInitialBootstrap: Bool {
        syncGate.hasCompletedInitialBootstrap
    }

    var isSyncing: Bool {
        syncGate.phase == .syncing || syncGate.phase == .bootstrapping || syncGate.isManualSyncing
    }

    @discardableResult
    func transitionPhaseForTests(to target: Phase) -> Bool {
        guard syncGate.phase == .idle else { return false }
        syncGate.phase = target
        return true
    }

    func resetPhaseForTests() {
        syncGate.phase = .idle
        syncGate.isManualSyncing = false
    }
}
