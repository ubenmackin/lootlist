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
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "Security")
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

    private struct DiscoveredFamilyCandidate {
        let family: Family
        let profile: Profile
        let zoneID: CKRecordZone.ID
    }

    var authStatus: AuthStatus

    /// Explicit state machine serializing auth transitions and owning the persisted-session check.
    @ObservationIgnored
    private(set) lazy var authStateMachine: AuthStateMachine = .init(defaults: defaults, appState: self)

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
    /// Incremented as a UUID signal so SwiftUI `.onChange` and the lifecycle coordinator
    /// can observe zone identity changes without a stringly-typed notification.
    var familyZoneIDChangeSignal: UUID = .init()

    /// Typed replacement for the former `familyAccessRevoked` NotificationCenter channel.
    /// Bumped when the shared zone becomes unreachable (revoked hero) so UI can surface
    /// a toast via `.onChange(of: familyAccessRevokedSignal)` instead of observing a notification.
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
    /// thin session holder (`authStatus`, `currentProfile`, `family`,
    /// `familyZoneID`, `isZoneOwner`). Discovery no longer checks `authStatus`.
    var discoveryService: FamilyDiscoveryService?

    /// CloudKit-free mirror of the iCloud account status for UI consumption.
    var cloudAccountStatus: CloudAccountStatus = .couldNotDetermine

    /// Convenience for debug overlays — resolves the active family record name without exposing CloudKit
    /// zone internals.
    var activeFamilyRecordName: String? {
        family?.id.recordName
    }

    @ObservationIgnored
    private var quickActionTask: Task<Void, Never>?

    @ObservationIgnored
    private var notificationRouteTask: Task<Void, Never>?

    private actor DiscoveryCoordinator {
        private var isInFlight = false
        private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

        var isRunning: Bool {
            isInFlight
        }

        func begin() -> Bool {
            if isInFlight {
                return false
            }
            isInFlight = true
            return true
        }

        func finish() {
            isInFlight = false
            let pending = Array(waiters.values)
            waiters.removeAll()
            for waiter in pending {
                waiter.resume()
            }
        }

        func wait() async {
            guard isInFlight else { return }
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    if Task.isCancelled {
                        continuation.resume()
                    } else {
                        waiters[id] = continuation
                    }
                }
            } onCancel: {
                Task { await self.cancelWaiter(id: id) }
            }
        }

        private func cancelWaiter(id: UUID) {
            if let waiter = waiters.removeValue(forKey: id) {
                waiter.resume()
            }
        }
    }

    @ObservationIgnored
    private let discoveryCoordinator = DiscoveryCoordinator()

    // MARK: - Session Persistence Keys

    private static let profileIDKey = "session_profileRecordName"
    private static let familyIDKey = "session_familyRecordName"
    private static let zoneNameKey = "session_familyZoneName"
    private static let zoneOwnerKey = "session_familyZoneOwnerName"
    private static let isOwnerKey = "session_isZoneOwner"
    private static let hasSessionKey = "session_hasActiveSession"
    private static let hasOnboardedKey = "session_hasOnboarded"
    private static let abandonedZoneIDsKey = "session_abandonedFamilyZoneNames"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Screenshot and assertion suites depend on the utility surface
        // rendering deterministically; a flag toggled manually on a shared
        // simulator must never leak the immersive layer into a test run.
        if TestEnvironment.isRunningUITests {
            FeatureFlags.rpgImmersive = false
        }
        let hasSession = defaults.bool(forKey: Self.hasSessionKey)
        // A completed onboarding that lacks a session means we should probe for a recoverable family (restore
        // / reconnect); a brand-new install goes straight to the discovery state so RootView renders the
        authStatus = hasSession ? .restoringSession : .checkingCloudData

        quickActionTask = Task { @MainActor [weak self] in
            for await notification in NotificationCenter.default.notifications(named: .quickActionTriggered) {
                if let action = notification.object as? QuickActionType {
                    self?.pendingQuickAction = action
                }
            }
        }

        notificationRouteTask = Task { @MainActor [weak self] in
            // Cold-start route is now transferred by `AppDependencies` after it
            // creates the owned `NotificationRouter`; we still adopt any
            // fallback that slipped through before that hand-off.
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
    }

    deinit {
        quickActionTask?.cancel()
        notificationRouteTask?.cancel()
    }

    // MARK: - Abandoned Zone Queue Management

    var abandonedZoneIDs: [String] {
        get {
            defaults.stringArray(forKey: Self.abandonedZoneIDsKey) ?? []
        }
        set {
            defaults.set(newValue, forKey: Self.abandonedZoneIDsKey)
        }
    }

    func addAbandonedZoneID(_ zoneName: String) {
        var current = abandonedZoneIDs
        if !current.contains(zoneName) {
            current.append(zoneName)
            abandonedZoneIDs = current
        }
    }

    func removeAbandonedZoneID(_ zoneName: String) {
        var current = abandonedZoneIDs
        current.removeAll { $0 == zoneName }
        abandonedZoneIDs = current
    }

    func saveSession(profile: Profile, family: Family, zoneID: CKRecordZone.ID, isOwner: Bool) {
        defaults.set(profile.id.recordName, forKey: Self.profileIDKey)
        defaults.set(family.id.recordName, forKey: Self.familyIDKey)
        defaults.set(zoneID.zoneName, forKey: Self.zoneNameKey)
        defaults.set(zoneID.ownerName, forKey: Self.zoneOwnerKey)
        defaults.set(isOwner, forKey: Self.isOwnerKey)
        defaults.set(true, forKey: Self.hasSessionKey)
        defaults.set(true, forKey: Self.hasOnboardedKey)
    }

    func clearSession() {
        // Clear in-memory session pointers first so any active view observers
        // immediately see a cleared session and do not re-fetch from the cache
        // while it is being purged.
        let previousFamilyRecordName = defaults.string(forKey: Self.familyIDKey)
        signOutInternal()

        if let previousFamilyRecordName {
            cacheService?.purgeFamily(recordName: previousFamilyRecordName)
            Task {
                await backgroundCacheActor?.purgeFamily(recordName: previousFamilyRecordName)
            }
        }

        defaults.removeObject(forKey: Self.profileIDKey)
        defaults.removeObject(forKey: Self.familyIDKey)
        defaults.removeObject(forKey: Self.zoneNameKey)
        defaults.removeObject(forKey: Self.zoneOwnerKey)
        defaults.removeObject(forKey: Self.isOwnerKey)
        defaults.removeObject(forKey: Self.hasSessionKey)
        // Preserve `hasOnboardedKey` so the app knows this user has completed
        // onboarding before and should attempt recovery rather than showing
        // the brand-new Welcome screen on the next launch.

        // Ensures scope key and coordinator reset when switching families to avoid stale sync.
        NotificationCenter.default.post(name: .didClearSession, object: nil)
    }

    /// Extended session clearing that also resets CloudKit scope and engine state.
    /// Prefer this over bare `clearSession()` when a CloudKit service reference is available.
    func clearSessionAndCloudKitScope(cloudKit: any CloudKitServiceProtocol, syncCoordinator: CKSyncEngineCoordinator? = nil) {
        // Clear CloudKit active scope to prevent stale family targeting
        cloudKit.activeFamilyZoneID = nil
        cloudKit.activeIsOwner = false

        // Clear any pending engine state so queued writes for the
        // previous family are not sent after switching.
        syncCoordinator?.resetState()

        clearSession()
    }

    // MARK: - Session Restoration

    func restoreSession(cloudKit: any CloudKitServiceProtocol) async {
        guard defaults.bool(forKey: Self.hasSessionKey),
              let profileRecordName = defaults.string(forKey: Self.profileIDKey),
              let familyRecordName = defaults.string(forKey: Self.familyIDKey),
              let zoneName = defaults.string(forKey: Self.zoneNameKey),
              let zoneOwnerName = defaults.string(forKey: Self.zoneOwnerKey)
        else {
            // A sign-in callback can finish discovery before the bootstrap task
            // reaches this branch. Do not reset a completed reconnect or
            // onboarding result and start a second discovery pass.
            guard authStatus == .checkingCloudData || authStatus == .restoringSession else { return }
            await authStateMachine.transition(.restoreFailed)
            await discoverExistingCloudState(cloudKit: cloudKit)
            return
        }

        let storedOwner = defaults.bool(forKey: Self.isOwnerKey)
        let isPlaceholder = ActiveFamilyScopeGuard.isPlaceholderOwner(zoneOwnerName)
        let isOwner: Bool = isPlaceholder ? true : storedOwner
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: zoneOwnerName)

        isZoneOwner = isOwner
        cloudKit.activeFamilyZoneID = zoneID
        cloudKit.activeIsOwner = isOwner
        // Register the zone locally before fetching so a cold launch that has
        // not yet synced this device does not hit `zoneNotFound`.
        if isOwner {
            do {
                try await cloudKit.ensureZoneExists(zoneID)
            } catch {
                logger.warning("ensureZoneExists failed during restore for zone '\(zoneID.zoneName, privacy: .private)': \(error, privacy: .private) — proceeding to fetch")
            }
        }
        let db = cloudKit.database(isOwner: isOwner)

        let profileID = CKRecord.ID(recordName: profileRecordName, zoneID: zoneID)
        let familyID = CKRecord.ID(recordName: familyRecordName, zoneID: zoneID)

        do {
            async let fetchedProfile = cloudKit.fetch(Profile.self, id: profileID, using: db)
            async let fetchedFamily = cloudKit.fetch(Family.self, id: familyID, using: db)
            let (profile, familyResult) = try await (fetchedProfile, fetchedFamily)
            // Re-resolve identity fresh from CloudKit (not a cached record name) so
            // a stale iCloud identity after an account change cannot spuriously
            // authorize or block the session. Deny only when the mismatch is proven.
            try await ActiveFamilyScopeGuard.requireServerAuthenticatedIdentity(
                profile: profile,
                family: familyResult,
                zoneID: zoneID,
                isOwner: isOwner,
                cloudKit: cloudKit
            )

            // Set family before zoneID so the zone change notification sees a
            // consistent active family and does not trigger a spurious scope mismatch.
            family = familyResult
            currentProfile = profile
            let resolvedOwner = ActiveFamilyScopeGuard.resolvedIsOwner(appState: self)
            isZoneOwner = resolvedOwner
            if resolvedOwner != isOwner {
                defaults.set(resolvedOwner, forKey: Self.isOwnerKey)
                cloudKit.activeIsOwner = resolvedOwner
            }
            familyZoneID = zoneID

            authStatus = .authenticated
            await authStateMachine.send(.sessionRestored)
        } catch {
            await handleRestorationError(
                error: error,
                profileRecordName: profileRecordName,
                familyRecordName: familyRecordName,
                zoneID: zoneID,
                zoneOwnerName: zoneOwnerName,
                isOwner: isOwner,
                cloudKit: cloudKit
            )
        }
    }

    private func handleRestorationError(
        error: Error,
        profileRecordName: String,
        familyRecordName: String,
        zoneID: CKRecordZone.ID,
        zoneOwnerName: String,
        isOwner: Bool,
        cloudKit: any CloudKitServiceProtocol
    ) async {
        logger.error("Session restoration failed: \(error, privacy: .private)")
        if error is ScopeViolation {
            await handleScopeViolation(
                profileRecordName: profileRecordName,
                familyRecordName: familyRecordName,
                zoneID: zoneID,
                zoneOwnerName: zoneOwnerName,
                isOwner: isOwner,
                cloudKit: cloudKit
            )
            return
        }

        let isUnrecoverable = await isRestorationErrorUnrecoverable(
            error: error,
            isOwner: isOwner,
            familyRecordName: familyRecordName,
            zoneID: zoneID,
            cloudKit: cloudKit
        )

        if isUnrecoverable {
            if !isOwner,
               let cloudKitError = error as? CloudKitServiceError,
               case .zoneNotFound = cloudKitError
            {
                logger.info("Shared family zone is unavailable — clearing revoked hero session")
                familyAccessRevokedSignal = UUID()
                clearSessionAndCloudKitScope(cloudKit: cloudKit)
                await authStateMachine.transition(.restoreFailed)
                await discoverExistingCloudState(cloudKit: cloudKit)
                return
            }
            if !restoreFromCache(profileRecordName: profileRecordName, familyRecordName: familyRecordName, zoneID: zoneID, isOwner: isOwner) {
                logger.info("Unrecoverable CloudKit session error and no cache available — clearing session and running cloud discovery")
                clearSessionAndCloudKitScope(cloudKit: cloudKit)
                await authStateMachine.transition(.restoreFailed)
                await discoverExistingCloudState(cloudKit: cloudKit)
            }
        } else {
            // Transient network error — try cache fallback for offline launch
            if !restoreFromCache(profileRecordName: profileRecordName, familyRecordName: familyRecordName, zoneID: zoneID, isOwner: isOwner) {
                authStatus = .offlineEmptyCache
            }
        }
    }

    private func handleScopeViolation(
        profileRecordName: String,
        familyRecordName: String,
        zoneID: CKRecordZone.ID,
        zoneOwnerName: String,
        isOwner: Bool,
        cloudKit: any CloudKitServiceProtocol
    ) async {
        let isPlaceholderOwner = ActiveFamilyScopeGuard.isPlaceholderOwner(zoneOwnerName)
        if isPlaceholderOwner || isOwner {
            logger.info("ScopeViolation with placeholder/stale owner \(zoneOwnerName, privacy: .private) — clearing stale session and rediscovering")
            clearSessionAndCloudKitScope(cloudKit: cloudKit)
            await authStateMachine.transition(.restoreFailed)
            await discoverExistingCloudState(cloudKit: cloudKit)
            return
        }
        // For non-placeholder hero cases, keep the offline cache
        // fallback when the network/identity is transiently unavailable.
        if restoreFromCache(profileRecordName: profileRecordName, familyRecordName: familyRecordName, zoneID: zoneID, isOwner: isOwner) {
            return
        }
        clearSessionAndCloudKitScope(cloudKit: cloudKit)
        await authStateMachine.transition(.restoreFailed)
        await discoverExistingCloudState(cloudKit: cloudKit)
    }

    private func isRestorationErrorUnrecoverable(
        error: Error,
        isOwner: Bool,
        familyRecordName: String,
        zoneID: CKRecordZone.ID,
        cloudKit: any CloudKitServiceProtocol
    ) async -> Bool {
        if let ckErr = error as? CloudKitServiceError {
            switch ckErr {
            case .notFound, .invalidArguments, .zoneNotFound:
                return true
            default:
                break
            }
        }
        let reachable = await Self.isZoneReachable(
            cloudKit: cloudKit,
            familyRecordName: familyRecordName,
            zoneID: zoneID
        )
        return isOwner && !reachable
    }

    // MARK: - Session Restoration Helpers

    /// Attempts to restore the session from the local SwiftData cache.
    /// Returns `true` when the cache had valid profile and family data and the
    /// session was restored; `false` when the cache was empty or unavailable.
    private func restoreFromCache(
        profileRecordName: String,
        familyRecordName: String,
        zoneID: CKRecordZone.ID,
        isOwner: Bool
    ) -> Bool {
        guard let cache = cacheService else { return false }

        let cachedProfile = cache.fetchProfile(recordName: profileRecordName, family: familyRecordName)
        let cachedFamily = cache.fetchFamily(recordName: familyRecordName)
        guard let cachedProfile, let cachedFamily else {
            return false
        }

        // Assign family before zoneID for the same reason as in restoreSession — the
        // zone notification must not fire before the family context exists.
        family = cachedFamily.toFamily(zoneID: zoneID)
        currentProfile = cachedProfile.toProfile(zoneID: zoneID)
        let resolvedOwner = ActiveFamilyScopeGuard.resolvedIsOwner(appState: self)
        isZoneOwner = resolvedOwner
        if resolvedOwner != isOwner {
            defaults.set(resolvedOwner, forKey: Self.isOwnerKey)
        }
        familyZoneID = zoneID
        authStatus = .authenticated
        logger.info("Session restored from local cache (offline mode)")
        // A cache hit implies a prior successful sync; stamp the
        // family/profile freshness gates so the first launch after
        // a transient CloudKit failure does not re-fetch them.
        cache.markCacheFresh(familyRecordName: familyRecordName, type: .family)
        cache.markCacheFresh(familyRecordName: familyRecordName, type: .profile)
        return true
    }

    /// Zone reachability now delegates to `FamilyDiscoveryService` so session
    /// restoration does not embed CloudKit query logic.
    private static func isZoneReachable(
        cloudKit: any CloudKitServiceProtocol,
        familyRecordName: String,
        zoneID: CKRecordZone.ID
    ) async -> Bool {
        let service = FamilyDiscoveryService()
        return await service.isZoneReachable(
            cloudKit: cloudKit,
            familyRecordName: familyRecordName,
            zoneID: zoneID
        )
    }

    // MARK: - Cloud State Discovery — thin delegation

    /// Thin delegation to `FamilyDiscoveryService`. Discovery itself no longer
    /// checks `authStatus`; this wrapper keeps coalescing and session gating
    /// while the service owns the CloudKit queries.
    func discoverExistingCloudState(cloudKit: any CloudKitServiceProtocol) async {
        let canStart = await discoveryCoordinator.begin()
        if !canStart {
            logger.info("Cloud state discovery joined the in-progress discovery")
            await discoveryCoordinator.wait()
            return
        }

        defer {
            Task { await self.discoveryCoordinator.finish() }
        }

        if case .detectedPreviousFamily = authStatus {
            return
        }
        if case .authenticated = authStatus {
            return
        }

        if family != nil, currentProfile != nil {
            authStatus = .authenticated
            return
        }

        let service = discoveryService ?? FamilyDiscoveryService()
        let result = await service.discoverExistingCloudState(cloudKit: cloudKit)
        switch result {
        case let .owner(candidate):
            authStatus = .detectedPreviousFamily(family: candidate.family, profile: candidate.profile, zoneID: candidate.zoneID, isOwner: true)
        case let .hero(candidate):
            authStatus = .detectedPreviousFamily(family: candidate.family, profile: candidate.profile, zoneID: candidate.zoneID, isOwner: false)
        case .none:
            authStatus = .onboarding
        }
    }

    // MARK: - Discovery helpers — forwarded to FamilyDiscoveryService

    private func resolveCurrentUserRecordID(cloudKit: any CloudKitServiceProtocol) async -> CKRecord.ID? {
        let service = discoveryService ?? FamilyDiscoveryService()
        return await service.resolveCurrentUserRecordID(cloudKit: cloudKit)
    }

    // MARK: - Shared-Zone Hero Discovery Helpers — thin shims for existing callers

    /// Shim for `OnboardingViewModel` and tests; forwards to `FamilyDiscoveryService`.
    static func activeSharedHeroProfiles(
        cloudKit: any CloudKitServiceProtocol,
        userRecordID: CKRecord.ID?,
        zoneID: CKRecordZone.ID
    ) async -> [Profile] {
        let service = FamilyDiscoveryService()
        return await service.activeSharedHeroProfiles(
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
        let service = FamilyDiscoveryService()
        return await service.sharedZoneFamily(cloudKit: cloudKit, zoneID: zoneID)
    }

    func acceptDetectedFamily(familyCache: FamilyCache, profileCache: ProfileCache, zoneID: CKRecordZone.ID, isOwner: Bool, cloudKit: any CloudKitServiceProtocol) async {
        await acceptDetectedFamily(
            family: familyCache.toFamily(zoneID: zoneID),
            profile: profileCache.toProfile(zoneID: zoneID),
            zoneID: zoneID,
            isOwner: isOwner,
            cloudKit: cloudKit
        )
    }

    func acceptDetectedFamily(familyCache: FamilyCache, profileCache: ProfileCache, zoneIDString: String, isOwner: Bool, cloudKit: any CloudKitServiceProtocol) async {
        let zoneID = CKRecordZone.ID(zoneName: zoneIDString, ownerName: CKCurrentUserDefaultName)
        await acceptDetectedFamily(
            familyCache: familyCache,
            profileCache: profileCache,
            zoneID: zoneID,
            isOwner: isOwner,
            cloudKit: cloudKit
        )
    }

    func acceptDetectedFamily(family: Family, profile: Profile, zoneID: CKRecordZone.ID, isOwner _: Bool, cloudKit: any CloudKitServiceProtocol) async {
        self.family = family
        self.currentProfile = profile
        let resolvedOwner = ActiveFamilyScopeGuard.resolvedIsOwner(appState: self)
        do {
            try await ActiveFamilyScopeGuard.requireServerAuthenticatedIdentity(
                profile: profile,
                family: family,
                zoneID: zoneID,
                isOwner: resolvedOwner,
                cloudKit: cloudKit
            )
        } catch {
            logger.error("Rejected family recovery because server identity validation failed: \(error, privacy: .private)")
            self.family = nil
            self.currentProfile = nil
            authStatus = .onboarding
            return
        }
        saveSession(profile: profile, family: family, zoneID: zoneID, isOwner: resolvedOwner)
        isZoneOwner = resolvedOwner
        familyZoneID = zoneID
        cloudKit.activeFamilyZoneID = zoneID
        cloudKit.activeIsOwner = resolvedOwner
        authStatus = .authenticated
    }

    func rejectDetectedFamily(familyCache: FamilyCache, profileCache: ProfileCache, zoneID: CKRecordZone.ID, isOwner: Bool, cloudKit: any CloudKitServiceProtocol) async {
        await rejectDetectedFamily(
            family: familyCache.toFamily(zoneID: zoneID),
            profile: profileCache.toProfile(zoneID: zoneID),
            zoneID: zoneID,
            isOwner: isOwner,
            cloudKit: cloudKit
        )
    }

    func rejectDetectedFamily(familyCache: FamilyCache, profileCache: ProfileCache, zoneIDString: String, isOwner: Bool, cloudKit: any CloudKitServiceProtocol) async {
        let zoneID = CKRecordZone.ID(zoneName: zoneIDString, ownerName: CKCurrentUserDefaultName)
        await rejectDetectedFamily(
            familyCache: familyCache,
            profileCache: profileCache,
            zoneID: zoneID,
            isOwner: isOwner,
            cloudKit: cloudKit
        )
    }

    func rejectDetectedFamily(family _: Family, profile: Profile, zoneID: CKRecordZone.ID, isOwner: Bool, cloudKit: any CloudKitServiceProtocol) async {
        if isOwner {
            addAbandonedZoneID(zoneID.zoneName)
            do {
                try await cloudKit.deleteZone(zoneID)
                removeAbandonedZoneID(zoneID.zoneName)
            } catch {
                logger.error("Failed to delete zone on rejection: \(error, privacy: .private)")
            }
        } else {
            var deactivated = profile
            deactivated.isActive = false
            let db = cloudKit.database(isOwner: false)
            do {
                _ = try await cloudKit.save(deactivated, in: zoneID, using: db)
            } catch {
                logger.error("Failed to save profile deactivation on rejection: \(error, privacy: .private)")
            }
        }
        clearSessionAndCloudKitScope(cloudKit: cloudKit)
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
        let alreadyInFlight = await discoveryCoordinator.isRunning
        if alreadyInFlight {
            // Clear local session immediately, then await in-flight discovery completion before fresh scan.
            clearSessionAndCloudKitScope(cloudKit: cloudKit, syncCoordinator: syncCoordinator)
            authStatus = .checkingCloudData
            await discoveryCoordinator.wait()
            // Run fresh discovery scan reflecting the cleared session.
            authStatus = .checkingCloudData
            await discoverExistingCloudState(cloudKit: cloudKit)
            return
        }
        clearSessionAndCloudKitScope(cloudKit: cloudKit, syncCoordinator: syncCoordinator)
        authStatus = .checkingCloudData // flip to state discoverExistingCloudState requires
        await discoverExistingCloudState(cloudKit: cloudKit)
    }

    /// Resets in-memory state to onboarding root after cache and defaults are cleared.
    private func signOutInternal() {
        authStatus = .onboarding
        currentProfile = nil
        family = nil
        familyZoneID = nil
        isZoneOwner = false
    }
}
