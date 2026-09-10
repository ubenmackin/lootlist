//
//  AppState.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import CloudKit
import Foundation
import os

extension Notification.Name {
    static let didClearSession = Notification.Name("didClearSession")
    static let familyRosterChanged = Notification.Name("familyRosterChanged")
}

/// WHY typed signals: stringly-typed channels lose payloads and ordering, so
/// quick actions and notification routes ride AsyncStream buses with cold-start
/// retention. NotificationCenter posts remain as a legacy ingress adapter until
/// all producers emit directly.
@MainActor
final class QuickActionSignalBus {
    private static var continuations: [UUID: AsyncStream<QuickActionType>.Continuation] = [:]
    private static var retainedAction: QuickActionType?

    static func emit(_ action: QuickActionType) {
        retainedAction = action
        for (_, continuation) in continuations {
            continuation.yield(action)
        }
    }

    static func takePending() -> QuickActionType? {
        defer { retainedAction = nil }
        return retainedAction
    }

    static func stream() -> AsyncStream<QuickActionType> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { _ in
                Task { await MainActor.run { continuations.removeValue(forKey: id) } }
            }
        }
    }
}

/// WHY retained route: taps arriving before the first subscriber (cold start)
/// must still navigate once views mount, so the bus keeps the last route.
@MainActor
final class NotificationRouteSignalBus {
    private static var continuations: [UUID: AsyncStream<NotificationRoute>.Continuation] = [:]
    private static var retainedRoute: NotificationRoute?

    static func emit(_ route: NotificationRoute) {
        retainedRoute = route
        for (_, continuation) in continuations {
            continuation.yield(route)
        }
    }

    static func takePending() -> NotificationRoute? {
        defer { retainedRoute = nil }
        return retainedRoute
    }

    static func stream() -> AsyncStream<NotificationRoute> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { _ in
                Task { await MainActor.run { continuations.removeValue(forKey: id) } }
            }
        }
    }
}

@MainActor
@Observable
final class AppState {
    private static let logger = Logger(category: "Security")
    private var logger: Logger {
        Self.logger
    }

    enum AuthStatus: Equatable, Sendable {
        case restoringSession
        case checkingCloudData
        case detectedPreviousFamily(family: Family, profile: Profile, zoneID: CKRecordZone.ID, isOwner: Bool)
        case onboarding
        case authenticated
        case offlineEmptyCache
    }

    enum AppStateError: Error, Equatable, Sendable, LocalizedError {
        case cacheInitializationFailed(String)

        var errorDescription: String? {
            switch self {
            case .cacheInitializationFailed:
                "Failed to initialize the local cache. Please try relaunching the app."
            }
        }
    }

    var authStatus: AuthStatus

    /// Explicit state machine serializing auth transitions and owning the persisted-session check.
    @ObservationIgnored
    private(set) lazy var authStateMachine: AuthStateMachine = .init(defaults: defaults, appState: self)

    /// Observable auth and family state only; persistence lives in SessionStorage,
    /// discovery and recovery live in AuthenticationCoordinator.
    let sessionStorage: SessionStorage

    @ObservationIgnored
    private(set) lazy var authCoordinator: AuthenticationCoordinator = .init(appState: self)

    /// Safe on @MainActor — this didSet runs on the main actor where QuickActionManager touches UIApplication shortcutItems.
    var currentProfile: Profile? {
        didSet {
            QuickActionManager.updateQuickActions(for: currentProfile?.role)
        }
    }

    func updateCurrentProfileFromCache() {
        guard let current = currentProfile,
              let zoneID = familyZoneID,
              let cache = cacheService,
              let cached = cache.fetchProfile(recordName: current.id.recordName, family: family?.id.recordName ?? current.family.recordID.recordName),
              !cached.isDeleted
        else { return }

        let updated = current.mergingCacheValues(from: cached.toProfile(zoneID: zoneID))

        // Compare the FULL cached profile, not a field subset. A cross-device change to payoutPolicy,
        // payoutDay, or customAvatarImageData must propagate to currentProfile exactly like an
        guard updated != currentProfile else { return }
        logger.info("Updating currentProfile from cache (XP: \(self.currentProfile?.xp ?? 0) -> \(updated.xp), Level: \(self.currentProfile?.level ?? 0) -> \(updated.level))")
        currentProfile = updated
    }

    /// Returns `true` only for the profile belonging to the authenticated
    /// session and its active family zone. Callers must not use a profile
    /// supplied by a view or notification as an authorization substitute.
    func isAuthenticatedActiveProfile(_ profile: Profile) -> Bool {
        guard authStatus == .authenticated,
              let activeProfile = currentProfile,
              activeProfile.id == profile.id,
              let family,
              let familyZoneID
        else {
            return false
        }

        return activeProfile.family.recordID == family.id
            && activeProfile.id.zoneID == familyZoneID
            && profile.family.recordID == family.id
            && profile.id.zoneID == familyZoneID
    }

    var pendingQuickAction: QuickActionType?

    var pendingNotificationRoute: NotificationRoute?

    var family: Family?

    /// Typed replacement for the former `didChangeFamilyZoneID` NotificationCenter channel.
    var familyZoneIDChangeSignal: UUID = .init()

    /// Typed replacement for the former `familyAccessRevoked` NotificationCenter channel.
    var familyAccessRevokedSignal: UUID = .init()

    /// Direct callback for the lifecycle coordinator to invalidate scope without
    /// going through NotificationCenter. Set by `AppLifecycleCoordinator` after init.
    @ObservationIgnored
    var onFamilyZoneIDChange: (() -> Void)?

    // MARK: - Active Family Zone

    var familyZoneID: CKRecordZone.ID? {
        didSet {
            guard oldValue != familyZoneID else { return }
            // WHY family-before-zone: callers assign `family` first so zone
            // observers always see consistent family context on change.
            familyZoneIDChangeSignal = UUID()
            onFamilyZoneIDChange?()
        }
    }

    func resolvedFamilyZoneID(fallbackRecord: (any FamilyScopedCache)? = nil) -> CKRecordZone.ID {
        let defaultZone = CKRecordZone.default().zoneID
        return familyZoneID ?? family?.id.zoneID ?? fallbackRecord?.validatedZoneID(requestedZoneID: defaultZone) ?? defaultZone
    }

    var resolvedPayoutDay: PayoutDay {
        PayoutDayResolver.resolved(for: currentProfile, family: family)
    }

    var isZoneOwner: Bool = false

    /// Single source of truth for the owner-derived database scope. Every
    /// service route that previously inlined the ternary now derives scope
    /// from this property.
    var activeDatabaseScope: CKDatabase.Scope {
        DatabaseScopeResolver.scope(isOwner: ActiveFamilyScopeGuard.resolvedIsOwner(appState: self))
    }

    var cacheService: CacheService?
    var backgroundCacheActor: BackgroundCacheActor?
    var cacheInitError: AppStateError?

    /// Discovery service injected via `AppDependencies` so `AppState` stays a
    /// thin session holder. Discovery no longer checks `authStatus`.
    var discoveryService: FamilyDiscoveryService?

    /// CloudKit-free mirror of the iCloud account status for UI consumption.
    var cloudAccountStatus: CloudAccountStatus = .couldNotDetermine

    /// Convenience for debug overlays — resolves the active family record name without exposing CloudKit
    /// zone internals.
    var activeFamilyRecordName: String? {
        family?.id.recordName
    }

    @ObservationIgnored
    private var signalObservationTask: Task<Void, Never>?

    // MARK: - Session Persistence

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        let storage = SessionStorage(defaults: defaults)
        self.sessionStorage = storage
        self.defaults = defaults
        if TestEnvironment.isRunningUITests {
            FeatureFlags.rpgImmersive = false
        }
        let hasSession = storage.hasActiveSession
        authStatus = hasSession ? .restoringSession : .checkingCloudData

        startSignalObservation()
    }

    /// Single handling path for quick-action taps, including cold-start taps
    /// retained by the bus before the first subscriber mounted.
    func handleQuickAction(_ action: QuickActionType) {
        pendingQuickAction = action
    }

    /// Single handling path for notification routes, including cold-start taps
    /// retained by the router or the bus before views mounted.
    func handleNotificationRoute(_ route: NotificationRoute) {
        pendingNotificationRoute = route
    }

    /// WHY discarding group: the two signal loops share one cancellable scope so
    /// teardown cancels both without per-task locks. AppState lives for the
    /// process lifetime, so loops break on weak-self nil and need no deinit hop.
    private func startSignalObservation() {
        // WHY drain-before-subscribe: cold-start taps park before this listener
        // exists, so retained routes land before the live stream resumes.
        if let pending = QuickActionSignalBus.takePending() {
            pendingQuickAction = pending
        }
        if let router = AppDependencies.shared?.notificationRouter,
           let pending = router.takePendingRoute()
        {
            pendingNotificationRoute = pending
        }
        if let retained = NotificationRouteSignalBus.takePending() {
            pendingNotificationRoute = retained
        }
        signalObservationTask = Task { [weak self] in
            await withDiscardingTaskGroup { group in
                group.addTask { [weak self] in await self?.observeQuickActionSignals() }
                group.addTask { [weak self] in await self?.observeNotificationRouteSignals() }
            }
        }
    }

    /// Explicit teardown for previews and tests; production lifetime needs no call.
    func stopSignalObservation() {
        signalObservationTask?.cancel()
        signalObservationTask = nil
    }

    private func observeQuickActionSignals() async {
        let signalStream = QuickActionSignalBus.stream()
        await withDiscardingTaskGroup { group in
            group.addTask { [weak self] in
                for await action in signalStream {
                    guard !Task.isCancelled else { break }
                    guard let self else { break }
                    // WHY hop: signal sequence resumes off isolation, so re-enter MainActor before touching view state.
                    await MainActor.run { self.handleQuickAction(action) }
                }
            }
            group.addTask {
                // WHY legacy ingress: unmigrated producers still post NotificationCenter,
                // so forward into the typed bus and let the bus path handle retention.
                for await notification in NotificationCenter.default.notifications(named: .quickActionTriggered) {
                    guard !Task.isCancelled else { break }
                    if let action = notification.object as? QuickActionType {
                        await MainActor.run { QuickActionSignalBus.emit(action) }
                    }
                }
            }
        }
    }

    private func observeNotificationRouteSignals() async {
        let signalStream = NotificationRouteSignalBus.stream()
        await withDiscardingTaskGroup { group in
            group.addTask { [weak self] in
                for await route in signalStream {
                    guard !Task.isCancelled else { break }
                    guard let self else { break }
                    // WHY hop: signal sequence resumes off isolation, so re-enter MainActor before touching view state.
                    await MainActor.run { self.handleNotificationRoute(route) }
                }
            }
            group.addTask {
                // WHY legacy ingress: the router still posts NotificationCenter,
                // so forward into the typed bus for single-path handling.
                for await notification in NotificationCenter.default.notifications(named: .notificationRouteTriggered) {
                    guard !Task.isCancelled else { break }
                    if let route = notification.object as? NotificationRoute {
                        await MainActor.run { NotificationRouteSignalBus.emit(route) }
                    }
                }
            }
        }
    }

    // MARK: - SessionStorage Delegation

    var abandonedZoneIDs: [String] {
        get { sessionStorage.abandonedFamilyZoneNames }
        set { sessionStorage.abandonedFamilyZoneNames = newValue }
    }

    func addAbandonedZoneID(_ zoneName: String) {
        sessionStorage.addAbandonedZoneID(zoneName)
    }

    func removeAbandonedZoneID(_ zoneName: String) {
        sessionStorage.removeAbandonedZoneID(zoneName)
    }

    func saveSession(profile: Profile, family: Family, zoneID: CKRecordZone.ID, isOwner: Bool) {
        sessionStorage.save(profile: profile, family: family, zoneID: zoneID, isOwner: isOwner)
    }

    func clearSession() {
        authCoordinator.clearSession()
    }

    /// Extended session clearing that also resets CloudKit scope and engine state.
    func clearSessionAndCloudKitScope(cloudKit: any CloudKitServiceProtocol, syncCoordinator: CKSyncEngineCoordinator? = nil) {
        authCoordinator.clearSessionAndCloudKitScope(cloudKit: cloudKit, syncCoordinator: syncCoordinator)
    }

    func restoreSession(cloudKit: any CloudKitServiceProtocol) async {
        await authCoordinator.restoreSession(cloudKit: cloudKit)
    }

    func discoverExistingCloudState(cloudKit: any CloudKitServiceProtocol) async {
        await authCoordinator.discoverExistingCloudState(cloudKit: cloudKit)
    }

    /// Shim for `OnboardingViewModel` and tests; forwards to `FamilyDiscoveryService`.
    static func activeSharedHeroProfiles(
        cloudKit: any CloudKitServiceProtocol,
        userRecordID: CKRecord.ID?,
        zoneID: CKRecordZone.ID
    ) async -> [Profile] {
        await AuthenticationCoordinator.activeSharedHeroProfiles(
            cloudKit: cloudKit,
            userRecordID: userRecordID,
            zoneID: zoneID
        )
    }

    /// Shim for existing callers; forwards to `FamilyDiscoveryService`.
    static func sharedZoneFamily(
        cloudKit: any CloudKitServiceProtocol,
        zoneID: CKRecordZone.ID
    ) async -> Family? {
        await AuthenticationCoordinator.sharedZoneFamily(cloudKit: cloudKit, zoneID: zoneID)
    }

    func acceptDetectedFamily(
        familyCache: FamilyCache,
        profileCache: ProfileCache,
        zoneName: String,
        zoneOwnerName: String,
        isOwner: Bool,
        cloudKit: any CloudKitServiceProtocol
    ) async {
        await authCoordinator.acceptDetectedFamily(
            familyCache: familyCache,
            profileCache: profileCache,
            zoneName: zoneName,
            zoneOwnerName: zoneOwnerName,
            isOwner: isOwner,
            cloudKit: cloudKit
        )
    }

    func acceptDetectedFamily(family: Family, profile: Profile, zoneID: CKRecordZone.ID, isOwner: Bool, cloudKit: any CloudKitServiceProtocol) async {
        await authCoordinator.acceptDetectedFamily(
            family: family,
            profile: profile,
            zoneID: zoneID,
            isOwner: isOwner,
            cloudKit: cloudKit
        )
    }

    func rejectDetectedFamily(
        familyCache: FamilyCache,
        profileCache: ProfileCache,
        zoneName: String,
        zoneOwnerName: String,
        isOwner: Bool,
        cloudKit: any CloudKitServiceProtocol
    ) async {
        await authCoordinator.rejectDetectedFamily(
            familyCache: familyCache,
            profileCache: profileCache,
            zoneName: zoneName,
            zoneOwnerName: zoneOwnerName,
            isOwner: isOwner,
            cloudKit: cloudKit
        )
    }

    func rejectDetectedFamily(family: Family, profile: Profile, zoneID: CKRecordZone.ID, isOwner: Bool, cloudKit: any CloudKitServiceProtocol) async {
        await authCoordinator.rejectDetectedFamily(
            family: family,
            profile: profile,
            zoneID: zoneID,
            isOwner: isOwner,
            cloudKit: cloudKit
        )
    }

    /// Performs device-local sign-out, resetting session and clearing local cache.
    func signOut(cloudKit: (any CloudKitServiceProtocol)? = nil, syncCoordinator: CKSyncEngineCoordinator? = nil) {
        if let cloudKit {
            clearSessionAndCloudKitScope(cloudKit: cloudKit, syncCoordinator: syncCoordinator)
        } else {
            clearSession()
        }
    }

    /// Wipes local session and scope, then immediately re-discovers existing iCloud state.
    func signOutAndDiscover(cloudKit: any CloudKitServiceProtocol, syncCoordinator: CKSyncEngineCoordinator? = nil) async {
        await authCoordinator.signOutAndDiscover(cloudKit: cloudKit, syncCoordinator: syncCoordinator)
    }
}
