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
    static let didChangeFamilyZoneID = Notification.Name("didChangeFamilyZoneID")
    static let familyAccessRevoked = Notification.Name("familyAccessRevoked")
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
    var authStateMachine: AuthStateMachine!

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

    // MARK: - Active Family Zone

    var familyZoneID: CKRecordZone.ID? {
        didSet {
            // Broadcast on any zone identity change so cached scope state is invalidated even before the family is
            // resolved.
            guard oldValue != familyZoneID else { return }
            NotificationCenter.default.post(name: .didChangeFamilyZoneID, object: nil)
        }
    }

    /// WHY: Call sites copy-pasted this fallback chain; one resolution point
    /// keeps family-zone targeting consistent. A cache row's persisted zone
    /// wins only when neither the session zone nor the family record has one.
    func resolvedFamilyZoneID(fallbackRecord: (any FamilyScopedCache)? = nil) -> CKRecordZone.ID {
        let defaultZone = CKRecordZone.default().zoneID
        return familyZoneID ?? family?.id.zoneID ?? fallbackRecord?.validatedZoneID(requestedZoneID: defaultZone) ?? defaultZone
    }

    /// WHY: Single source for effective payout-day resolution (profile override → family → .sunday) so week windows stay consistent.
    var resolvedPayoutDay: PayoutDay {
        PayoutDayResolver.resolved(for: currentProfile, family: family)
    }

    var isZoneOwner: Bool = false
    var cacheService: CacheService?
    var backgroundCacheActor: BackgroundCacheActor?
    var cacheInitError: AppStateError?

    /// WHY: CK-free mirror of the iCloud account status; the lifecycle layer
    /// refreshes it so views render published state instead of calling CloudKit.
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

    @ObservationIgnored
    private var isDiscoveryInFlight = false

    @ObservationIgnored
    private var discoveryWaiters: [CheckedContinuation<Void, Never>] = []

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
        authStateMachine = AuthStateMachine(defaults: defaults)
        authStateMachine.attach(to: self)

        quickActionTask = Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(named: .quickActionTriggered) {
                if let action = notification.object as? QuickActionType {
                    self?.pendingQuickAction = action
                }
            }
        }

        notificationRouteTask = Task { [weak self] in
            // Adopt a notification route retained by the router for taps that
            // arrived before this observer was subscribed (cold start), then
            // follow live posts.
            self?.pendingNotificationRoute = NotificationRouter.shared.takePendingRoute()
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

        let isOwner = defaults.bool(forKey: Self.isOwnerKey)
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: zoneOwnerName)

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
            isZoneOwner = isOwner
            familyZoneID = zoneID

            authStatus = .authenticated
            await authStateMachine.send(.sessionRestored)
        } catch {
            logger.error("Session restoration failed: \(error, privacy: .private)")
            if error is ScopeViolation {
                // Clear stale placeholder session and rediscover cloud state.
                let isPlaceholderOwner = zoneOwnerName == CKCurrentUserDefaultName
                    || zoneOwnerName == "__defaultOwner__"
                    || zoneOwnerName == "_defaultOwner_"
                    || zoneOwnerName == "Owner1"
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
                return
            }
            // Validates zone reachability before treating owner fetch errors as transient.
            let isUnrecoverable: Bool
            if let ckErr = error as? CloudKitServiceError {
                switch ckErr {
                case .notFound, .invalidArguments, .zoneNotFound:
                    isUnrecoverable = true
                default:
                    // `&&` takes an autoclosure, so the awaited probe is hoisted
                    // into a local `let` — autoclosures forbid `await`.
                    let reachable = await Self.isZoneReachable(
                        cloudKit: cloudKit,
                        familyRecordName: familyRecordName,
                        zoneID: zoneID
                    )
                    isUnrecoverable = isOwner && !reachable
                }
            } else {
                let reachable = await Self.isZoneReachable(
                    cloudKit: cloudKit,
                    familyRecordName: familyRecordName,
                    zoneID: zoneID
                )
                isUnrecoverable = isOwner && !reachable
            }

            if isUnrecoverable {
                if !isOwner,
                   let cloudKitError = error as? CloudKitServiceError,
                   case .zoneNotFound = cloudKitError
                {
                    // A revoked shared zone must not fall back to its cached
                    // session; that would leave a removed hero looking active.
                    logger.info("Shared family zone is unavailable — clearing revoked hero session")
                    NotificationCenter.default.post(name: .familyAccessRevoked, object: nil)
                    clearSessionAndCloudKitScope(cloudKit: cloudKit)
                    await authStateMachine.transition(.restoreFailed)
                    await discoverExistingCloudState(cloudKit: cloudKit)
                    return
                }
                // Falls back to local cache before clearing session if zone probe temporarily fails.
                if restoreFromCache(profileRecordName: profileRecordName, familyRecordName: familyRecordName, zoneID: zoneID, isOwner: isOwner) {
                    // Cache restored — session is back, no need to wipe.
                } else {
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
        isZoneOwner = isOwner
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

    /// Probes family zone reachability with a timeout to verify zone existence.
    private static func isZoneReachable(
        cloudKit: any CloudKitServiceProtocol,
        familyRecordName: String,
        zoneID: CKRecordZone.ID
    ) async -> Bool {
        let rootRecordID = CKRecord.ID(recordName: familyRecordName, zoneID: zoneID)
        let deadline = Date().addingTimeInterval(max(0.1, AppConstants.Session.zoneCheckTimeoutSeconds))
        for _ in 0 ..< max(1, AppConstants.Session.restoreRetryBudget) {
            if Date() >= deadline {
                return false
            }
            do {
                _ = try await cloudKit.fetchShareParticipants(for: rootRecordID)
                return true
            } catch {
                continue
            }
        }
        return false
    }

    // MARK: - Cloud State Discovery

    func discoverExistingCloudState(cloudKit: any CloudKitServiceProtocol) async {
        guard authStatus == .checkingCloudData else { return }

        if isDiscoveryInFlight {
            logger.info("Cloud state discovery joined the in-progress discovery")
            // Cancelled waiters remain until next discovery sweep — bounded (1 entry per cancelled launch) — acceptable; if strict, add onCancel cleanup.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                discoveryWaiters.append(continuation)
            }
            return
        }

        // If restoration has already populated the active session, a
        // redundant account-change callback must not replace it with
        // discovery and the "Guild Detected" screen.
        if family != nil, currentProfile != nil {
            authStatus = .authenticated
            return
        }

        isDiscoveryInFlight = true
        defer {
            isDiscoveryInFlight = false
            let waiters = discoveryWaiters
            discoveryWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }

        logger.info("Starting iCloud family discovery...")
        let userRecordID = await resolveCurrentUserRecordID(cloudKit: cloudKit)

        let ownerCandidates = await discoverPrivateOwnerCandidates(
            cloudKit: cloudKit,
            userRecordID: userRecordID
        )
        if ownerCandidates.count == 1, let owner = ownerCandidates.first {
            logger.info("SUCCESS: Detected Guild Master profile '\(owner.profile.displayName, privacy: .private)' in family '\(owner.family.name, privacy: .private)'")
            authStatus = .detectedPreviousFamily(family: owner.family, profile: owner.profile, zoneID: owner.zoneID, isOwner: true)
            return
        }
        if ownerCandidates.count > 1 {
            logger.warning("Rejecting ambiguous owner family discovery for the current iCloud account")
        }

        let heroCandidates = await discoverSharedHeroCandidates(
            cloudKit: cloudKit,
            userRecordID: userRecordID
        )
        if heroCandidates.count == 1, let hero = heroCandidates.first {
            logger.info("SUCCESS: Detected Hero profile '\(hero.profile.displayName, privacy: .private)' in shared family '\(hero.family.name, privacy: .private)'")
            authStatus = .detectedPreviousFamily(family: hero.family, profile: hero.profile, zoneID: hero.zoneID, isOwner: false)
            return
        }
        if heroCandidates.count > 1 {
            logger.warning("Rejecting ambiguous hero family discovery for the current iCloud account")
        }

        logger.info("Discovery complete — no active family detected. Transitioning to onboarding.")
        authStatus = .onboarding
    }

    private func resolveCurrentUserRecordID(cloudKit: any CloudKitServiceProtocol) async -> CKRecord.ID? {
        let userRecordID: CKRecord.ID?
        do {
            userRecordID = try await cloudKit.currentUserRecordID()
        } catch {
            logger.warning("Could not resolve current iCloud user record ID: \(error, privacy: .private)")
            userRecordID = nil
        }
        logger.info("Current user record ID: \(userRecordID?.recordName ?? "nil", privacy: .private)")
        return userRecordID
    }

    private func discoverPrivateOwnerCandidates(
        cloudKit: any CloudKitServiceProtocol,
        userRecordID: CKRecord.ID?
    ) async -> [DiscoveredFamilyCandidate] {
        do {
            let privateZones = try await cloudKit.fetchPrivateZones()
            logger.info("Found \(privateZones.count) private zones")
            let customZones = privateZones.filter { $0.zoneID.zoneName != "_defaultZone" && $0.zoneID.zoneName != "LootListZone" }

            var candidates: [DiscoveredFamilyCandidate] = []
            for zone in customZones {
                logger.info("Inspecting private custom zone: '\(zone.zoneID.zoneName, privacy: .private)'")
                let db = cloudKit.privateDatabase
                var family: Family?

                let familyID = CKRecord.ID(recordName: zone.zoneID.zoneName, zoneID: zone.zoneID)
                do {
                    family = try await cloudKit.fetch(Family.self, id: familyID, using: db)
                    if let family {
                        logger.info("Direct point lookup found Family: '\(family.name, privacy: .private)'")
                    }
                } catch {
                    logger.debug("Direct point lookup for Family in zone '\(zone.zoneID.zoneName, privacy: .private)' did not hit: \(error, privacy: .private)")
                }

                if family == nil {
                    do {
                        let families: [Family] = try await cloudKit.query(Family.self, predicate: NSPredicate(value: true), in: zone.zoneID, using: db)
                        family = families.count == 1 ? families.first : nil
                        if families.count > 1 {
                            logger.warning("Rejecting ambiguous Family records in private zone '\(zone.zoneID.zoneName, privacy: .private)'")
                        }
                        logger.info("Query fallback returned \(families.count) Family records.")
                    } catch {
                        logger.error("Query fallback error for zone '\(zone.zoneID.zoneName, privacy: .private)': \(error, privacy: .private)")
                    }
                }

                if let foundFamily = family,
                   let userRecordID
                {
                    // Accept families where the private zone is owned by current user despite placeholder creators.
                    let zoneOwner = zone.zoneID.ownerName
                    let isZoneOwnedByUser = zoneOwner == userRecordID.recordName
                        || zoneOwner == CKCurrentUserDefaultName
                        || zoneOwner == "__defaultOwner__"
                        || zoneOwner == "_defaultOwner_"
                    let familyCreatorMatches = foundFamily.creatorUserRecordName == userRecordID.recordName
                        || foundFamily.createdBy.recordName == userRecordID.recordName
                    let isPlaceholderFamilyCreator = AppConstants.Security.legacyPlaceholderCreators
                        .contains(foundFamily.creatorUserRecordName ?? "")
                        || AppConstants.Security.legacyPlaceholderCreators.contains(foundFamily.createdBy.recordName)
                    let shouldConsiderFamily = familyCreatorMatches || isZoneOwnedByUser || (isPlaceholderFamilyCreator && isZoneOwnedByUser)
                    guard shouldConsiderFamily else {
                        logger.info(
                            """
                            Skipping family '\(foundFamily.name, privacy: .private)' — owner mismatch \
                            (family creator \(foundFamily.creatorUserRecordName ?? "nil", privacy: .private), \
                            zone owner \(zoneOwner, privacy: .private))
                            """
                        )
                        continue
                    }
                    do {
                        let familyRef = CKRecord.Reference(recordID: foundFamily.id, action: .none)
                        let profiles: [Profile] = try await cloudKit.query(
                            Profile.self,
                            predicate: NSPredicate(format: "family == %@", familyRef),
                            in: zone.zoneID,
                            using: db
                        )
                        let matchingProfiles = profiles.filter {
                            let creatorOK = $0.creatorUserRecordName == userRecordID.recordName
                                || $0.creatorUserRecordName == nil
                                || AppConstants.Security.legacyPlaceholderCreators.contains($0.creatorUserRecordName ?? "")
                            return $0.isActive
                                && $0.role == .guildMaster
                                && $0.family.recordID == foundFamily.id
                                && creatorOK
                                && $0.iCloudUserID.recordName == userRecordID.recordName
                        }
                        guard matchingProfiles.count == 1, let activeProfile = matchingProfiles.first else {
                            if matchingProfiles.count > 1 {
                                logger.warning("Rejecting ambiguous owner identity in family '\(foundFamily.name, privacy: .private)'")
                            }
                            continue
                        }
                        candidates.append(DiscoveredFamilyCandidate(family: foundFamily, profile: activeProfile, zoneID: zone.zoneID))
                    } catch {
                        logger.error("Profile query error for zone '\(zone.zoneID.zoneName, privacy: .private)': \(error, privacy: .private)")
                    }
                }
            }
            return candidates
        } catch {
            logger.error("Error fetching private zones: \(error, privacy: .private)")
            return []
        }
    }

    private func discoverSharedHeroCandidates(
        cloudKit: any CloudKitServiceProtocol,
        userRecordID: CKRecord.ID?
    ) async -> [DiscoveredFamilyCandidate] {
        let sharedZones = await fetchSharedZonesWithBoundedRetry(cloudKit: cloudKit)

        logger.info("Final shared zones count: \(sharedZones.count)")

        var candidates: [DiscoveredFamilyCandidate] = []
        for zone in sharedZones {
            logger.info("Inspecting shared zone: '\(zone.zoneID.zoneName, privacy: .private)' (owner: '\(zone.zoneID.ownerName, privacy: .private)')")

            // Matches current user iCloud identity to avoid adopting another profile.
            let activeProfiles = await Self.activeSharedHeroProfiles(
                cloudKit: cloudKit,
                userRecordID: userRecordID,
                zoneID: zone.zoneID
            )
            if activeProfiles.count == 1,
               let activeHeroProfile = activeProfiles.first,
               let family = await Self.sharedZoneFamily(cloudKit: cloudKit, zoneID: zone.zoneID),
               activeHeroProfile.family.recordID == family.id
            {
                candidates.append(DiscoveredFamilyCandidate(family: family, profile: activeHeroProfile, zoneID: zone.zoneID))
            }
        }
        return candidates
    }

    private func fetchSharedZonesWithBoundedRetry(
        cloudKit: any CloudKitServiceProtocol
    ) async -> [CKRecordZone] {
        do {
            let sharedZones = try await cloudKit.fetchSharedZones()
            logger.info("Initial shared zones check: \(sharedZones.count) shared zones")

            // Retries zone lookup on cold start to allow accepted shares to settle.
            if sharedZones.isEmpty {
                for attempt in 1 ... AppConstants.Sync.maxPulseAttempts {
                    logger.info("Shared zone sync pulse attempt \(attempt)...")
                    do {
                        let retryZones = try await cloudKit.fetchSharedZones()
                        if !retryZones.isEmpty {
                            return retryZones
                        }
                    } catch {
                        logger.debug("Shared zone sync pulse attempt \(attempt) failed: \(error, privacy: .private)")
                    }
                }
            }

            return sharedZones
        } catch {
            logger.error("Error fetching shared zones: \(error, privacy: .private)")
            return []
        }
    }

    // MARK: - Shared-Zone Hero Discovery Helpers

    /// Finds active Profile matching current iCloud user in shared zones for recovery.
    static func activeSharedHeroProfiles(
        cloudKit: any CloudKitServiceProtocol,
        userRecordID: CKRecord.ID?,
        zoneID: CKRecordZone.ID
    ) async -> [Profile] {
        guard userRecordID != nil else { return [] }

        let profiles: [Profile]
        do {
            profiles = try await cloudKit.query(
                Profile.self,
                predicate: NSPredicate(value: true),
                in: zoneID,
                using: cloudKit.sharedDatabase
            )
        } catch {
            logger.error("Failed to query shared hero profiles in zone '\(zoneID.zoneName, privacy: .private)': \(error, privacy: .private)")
            return []
        }

        guard let userRecordName = userRecordID?.recordName else { return [] }

        var matches: [Profile] = []
        for profile in profiles where profile.isActive && profile.iCloudUserID.recordName == userRecordName {
            if let creatorUserRecordName = profile.creatorUserRecordName {
                guard creatorUserRecordName == userRecordName
                    || AppConstants.Security.legacyPlaceholderCreators.contains(creatorUserRecordName)
                else { continue }
                matches.append(profile)
                continue
            }

            let serverProfile: Profile
            do {
                serverProfile = try await cloudKit.fetch(
                    Profile.self,
                    id: profile.id,
                    using: cloudKit.sharedDatabase
                )
            } catch {
                logger
                    .debug(
                        "Shared profile fetch failed for '\(profile.id.recordName, privacy: .private)' (expected for revoked/missing shares): \(error, privacy: .private)"
                    )
                continue
            }

            guard serverProfile.isActive,
                  serverProfile.iCloudUserID.recordName == userRecordName,
                  serverProfile.creatorUserRecordName == userRecordName
                  || AppConstants.Security.legacyPlaceholderCreators.contains(serverProfile.creatorUserRecordName ?? ""),
                  serverProfile.family.recordID == profile.family.recordID
            else { continue }

            matches.append(serverProfile)
        }
        return matches.count == 1 ? matches : []
    }

    /// The `Family` record in a shared zone: a direct point lookup on the
    /// zone-named record first, with a full-zone query as fallback when the
    /// point lookup misses. Returns nil when neither path resolves a family.
    static func sharedZoneFamily(
        cloudKit: any CloudKitServiceProtocol,
        zoneID: CKRecordZone.ID
    ) async -> Family? {
        let familyID = CKRecord.ID(recordName: zoneID.zoneName, zoneID: zoneID)
        do {
            return try await cloudKit.fetch(Family.self, id: familyID, using: cloudKit.sharedDatabase)
        } catch {
            logger.debug("Point lookup for shared family in zone '\(zoneID.zoneName, privacy: .private)' missed: \(error, privacy: .private)")
        }

        do {
            let families = try await cloudKit.query(
                Family.self,
                predicate: NSPredicate(value: true),
                in: zoneID,
                using: cloudKit.sharedDatabase
            )
            return families.count == 1 ? families.first : nil
        } catch {
            logger.error("Fallback query for shared family in zone '\(zoneID.zoneName, privacy: .private)' failed: \(error, privacy: .private)")
            return nil
        }
    }

    func acceptDetectedFamily(familyCache: FamilyCache, profileCache: ProfileCache, zoneIDString: String, isOwner: Bool, cloudKit: any CloudKitServiceProtocol) async {
        let zoneID = CKRecordZone.ID(zoneName: zoneIDString, ownerName: CKCurrentUserDefaultName)
        await acceptDetectedFamily(
            family: familyCache.toFamily(zoneID: zoneID),
            profile: profileCache.toProfile(zoneID: zoneID),
            zoneID: zoneID,
            isOwner: isOwner,
            cloudKit: cloudKit
        )
    }

    func acceptDetectedFamily(family: Family, profile: Profile, zoneID: CKRecordZone.ID, isOwner: Bool, cloudKit: any CloudKitServiceProtocol) async {
        do {
            try await ActiveFamilyScopeGuard.requireServerAuthenticatedIdentity(
                profile: profile,
                family: family,
                zoneID: zoneID,
                isOwner: isOwner,
                cloudKit: cloudKit
            )
        } catch {
            logger.error("Rejected family recovery because server identity validation failed: \(error, privacy: .private)")
            authStatus = .onboarding
            return
        }
        saveSession(profile: profile, family: family, zoneID: zoneID, isOwner: isOwner)
        self.family = family
        currentProfile = profile
        isZoneOwner = isOwner
        familyZoneID = zoneID
        cloudKit.activeFamilyZoneID = zoneID
        cloudKit.activeIsOwner = isOwner
        authStatus = .authenticated
    }

    func rejectDetectedFamily(familyCache: FamilyCache, profileCache: ProfileCache, zoneIDString: String, isOwner: Bool, cloudKit: any CloudKitServiceProtocol) async {
        let zoneID = CKRecordZone.ID(zoneName: zoneIDString, ownerName: CKCurrentUserDefaultName)
        await rejectDetectedFamily(
            family: familyCache.toFamily(zoneID: zoneID),
            profile: profileCache.toProfile(zoneID: zoneID),
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
        if isDiscoveryInFlight {
            // Clear local session immediately, then await in-flight discovery completion before fresh scan.
            clearSessionAndCloudKitScope(cloudKit: cloudKit, syncCoordinator: syncCoordinator)
            authStatus = .checkingCloudData
            // Cancelled waiters remain until next discovery sweep — bounded (1 entry per cancelled launch) — acceptable; if strict, add onCancel cleanup.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                discoveryWaiters.append(continuation)
            }
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
