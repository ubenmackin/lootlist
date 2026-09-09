//
//  AppState.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import CloudKit
import Foundation
import os
import Synchronization

extension Notification.Name {
    static let didClearSession = Notification.Name("didClearSession")
    static let familyRosterChanged = Notification.Name("familyRosterChanged")
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
    private let quickActionTaskLock = Mutex<Task<Void, Never>?>(nil)

    @ObservationIgnored
    private let notificationRouteTaskLock = Mutex<Task<Void, Never>?>(nil)

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

        let qTask = Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(named: .quickActionTriggered) {
                if let action = notification.object as? QuickActionType {
                    self?.pendingQuickAction = action
                }
            }
        }
        quickActionTaskLock.withLock { $0 = qTask }

        let nTask = Task { [weak self] in
            if let router = AppDependencies.shared?.notificationRouter,
               let pending = router.takePendingRoute()
            {
                self?.pendingNotificationRoute = pending
            }
            for await notification in NotificationCenter.default.notifications(named: .notificationRouteTriggered) {
                if let route = notification.object as? NotificationRoute {
                    self?.pendingNotificationRoute = route
                }
            }
        }
        notificationRouteTaskLock.withLock { $0 = nTask }
    }

    deinit {
        quickActionTaskLock.withLock { $0?.cancel() }
        notificationRouteTaskLock.withLock { $0?.cancel() }
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
