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

/// Centralized sync/payout/migration trigger — single-flight state machine per ARCHITECTURE.md §4.
/// WHY: Mutex-guarded phase ensures bootstrapping/syncing/zoneChanging never overlap; manual sync uses separate flag so foreground sync does not starve user sync; reconnect flaps
/// debounced 45s.
@MainActor
@Observable
final class AppLifecycleCoordinator {
    // MARK: - Logging

    let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "LootList",
        category: "AppLifecycleCoordinator"
    )

    // MARK: - Lifecycle State Machine

    /// Single-flight state machine protecting the coordinator's in-flight flags.
    enum Phase: Equatable, Sendable {
        case idle
        case bootstrapping
        case syncing
        case zoneChanging
    }

    /// All mutable lifecycle flags are co-located in one `Mutex` so a single `withLock` can atomically test
    /// every guard that a caller cares about.
    /// WHY: single-flight — `phase` gates bootstrap/sync/zoneChanging (mutually exclusive); `isManualSyncing`
    /// is deliberately *outside* `phase` so manual sync is not starved when a foreground sync holds `.syncing`.
    /// `hasCompletedInitialBootstrap` prevents re-bootstrap; `lastReconnectTriggeredSyncAt` debounces flaps.
    struct LifecycleFlags: Sendable {
        var phase: Phase = .idle
        var isManualSyncing = false
        var hasCompletedInitialBootstrap = false
        var lastSynchronizedScopeKey: String?
        var lastObservedZoneID: (zoneName: String, ownerName: String)?
        var lastReconnectTriggeredSyncAt: Date?
    }

    let state = Mutex<LifecycleFlags>(LifecycleFlags())

    /// WHY: each reconnect-triggered sync runs a full multi-query CloudKit
    /// snapshot pass — connectivity flaps within this window coalesce into one.
    static let reconnectSyncMinimumInterval: TimeInterval = 45

    // MARK: - Debug Overlay Exposure

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

    /// Exposed for tests to assert the coordinator's current phase directly.
    var phaseForTests: Phase {
        state.withLock { $0.phase }
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
        sessionClearTask = Task { @MainActor [weak self] in
            #if DEBUG
                assert(Thread.isMainThread, "sessionClearTask must hop to MainActor")
            #endif
            for await _ in NotificationCenter.default.notifications(named: .didClearSession) {
                guard !Task.isCancelled, let self else { break }
                #if DEBUG
                    assert(Thread.isMainThread)
                #endif
                self.invalidateScopeStateForSessionClear()
            }
        }

        // Typed zone-change observation replaces the former `didChangeFamilyZoneID`
        // NotificationCenter channel. `AppState` bumps `familyZoneIDChangeSignal`
        // and invokes `onFamilyZoneIDChange` directly, so no stringly-typed
        // notification is needed and ordering is tied to the `@Observable` state
        // model (§4).
        appState.onFamilyZoneIDChange = { [weak self] in
            Task { @MainActor in self?.invalidateScopeForZoneChange() }
        }

        // Trigger automatic catch-up sync when network connectivity returns.
        // Throttled: rapid reconnect flaps must not each fire a full snapshot pass.
        networkReconnectTask = Task { @MainActor [weak self] in
            #if DEBUG
                assert(Thread.isMainThread, "networkReconnectTask must hop to MainActor")
            #endif
            for await _ in NotificationCenter.default.notifications(named: .networkDidReconnect) {
                guard !Task.isCancelled, let self else { break }
                #if DEBUG
                    assert(Thread.isMainThread)
                #endif
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

        accountChangeTask = Task { @MainActor [weak self] in
            #if DEBUG
                assert(Thread.isMainThread, "accountChangeTask must hop to MainActor")
            #endif
            for await _ in NotificationCenter.default.notifications(named: .CKAccountChanged) {
                guard !Task.isCancelled, let self, let appState = self.appState else { break }
                #if DEBUG
                    assert(Thread.isMainThread)
                #endif
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
        state.withLock { flags in
            flags.lastSynchronizedScopeKey = nil
            flags.lastObservedZoneID = nil
            flags.hasCompletedInitialBootstrap = false
        }
        logger.info("Cleared cached scope key and reset bootstrap completion for session clear")
    }

    /// Clears the cached scope key while keeping bootstrap completion intact
    /// when the active family zone changes mid-session.
    func invalidateScopeForZoneChange() {
        state.withLock { flags in
            flags.lastSynchronizedScopeKey = nil
            flags.lastObservedZoneID = nil
        }
        logger.info("Cleared cached scope key for zone change")
    }

    /// Detects in-process zone changes that occurred without triggering the
    /// `didChangeFamilyZoneID` notification.
    func handleZoneChangeIfNeeded(currentZoneID: CKRecordZone.ID) {
        state.withLock { flags in
            guard let last = flags.lastObservedZoneID else {
                flags.lastObservedZoneID = (zoneName: currentZoneID.zoneName, ownerName: currentZoneID.ownerName)
                return
            }
            if last.zoneName != currentZoneID.zoneName || last.ownerName != currentZoneID.ownerName {
                logger.info(
                    "Zone ID changed in-process: (\(last.zoneName), \(last.ownerName)) -> (\(currentZoneID.zoneName), \(currentZoneID.ownerName))"
                )
                flags.lastSynchronizedScopeKey = nil
                flags.lastObservedZoneID = (zoneName: currentZoneID.zoneName, ownerName: currentZoneID.ownerName)
            }
        }
    }

    // MARK: - Atomic Single-Flight Helpers

    func tryEnterBootstrap() -> Bool {
        state.withLock { flags in
            guard flags.phase == .idle, !flags.hasCompletedInitialBootstrap else {
                return false
            }
            flags.phase = .bootstrapping
            return true
        }
    }

    func tryEnterSync() -> Bool {
        state.withLock { flags in
            guard flags.hasCompletedInitialBootstrap, flags.phase == .idle else {
                return false
            }
            flags.phase = .syncing
            return true
        }
    }

    func tryEnterManualSync() -> Bool {
        state.withLock { flags in
            // Manual sync is user-initiated and must not be starved by a foreground sync holding `.syncing`.
            guard flags.phase != .bootstrapping else { return false }
            guard !flags.isManualSyncing else { return false }
            flags.isManualSyncing = true
            return true
        }
    }

    func tryEnterZoneChange(allowBeforeBootstrap: Bool = false) -> Bool {
        state.withLock { flags in
            guard flags.hasCompletedInitialBootstrap || allowBeforeBootstrap, flags.phase == .idle else {
                return false
            }
            flags.phase = .zoneChanging
            return true
        }
    }

    func exitPhase(_ phase: Phase) {
        state.withLock { flags in
            if flags.phase == phase {
                flags.phase = .idle
            }
        }
    }

    func exitManualSync() {
        state.withLock { flags in
            flags.isManualSyncing = false
        }
    }

    func forceResetPhaseForSignOut() {
        state.withLock { flags in
            flags.phase = .idle
            flags.isManualSyncing = false
            flags.hasCompletedInitialBootstrap = false
            flags.lastSynchronizedScopeKey = nil
            flags.lastObservedZoneID = nil
        }
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

    var isSyncing: Bool {
        state.withLock { $0.phase == .syncing || $0.phase == .bootstrapping || $0.isManualSyncing }
    }

    @discardableResult
    func transitionPhaseForTests(to target: Phase) -> Bool {
        state.withLock { flags in
            guard flags.phase == .idle else { return false }
            flags.phase = target
            return true
        }
    }

    func resetPhaseForTests() {
        state.withLock { flags in
            flags.phase = .idle
            flags.isManualSyncing = false
        }
    }
}
