//
//  AppState.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import CloudKit
import Foundation
import os

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

    var authStatus: AuthStatus {
        didSet {
            // An account event can arrive while a complete persisted session is
            // still waiting for restoreSession to run. Keep the launch splash
            // in place until that authoritative restoration attempt finishes.
            guard authStatus == .checkingCloudData,
                  oldValue == .restoringSession,
                  family == nil,
                  currentProfile == nil,
                  hasCompletePersistedSession()
            else { return }

            logger.info("Deferring account-change discovery until the persisted session is restored")
            authStatus = .restoringSession
        }
    }

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

        // Compare the FULL cached profile, not a field subset. A cross-device
        // change to payoutPolicy, payoutDay, or customAvatarImageData must
        // propagate to currentProfile exactly like an XP/level/name/avatar
        // change — the hero dashboard and treasury read these fields from
        // currentProfile and would otherwise stay stale indefinitely.
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

    var familyZoneID: CKRecordZone.ID?
    var isZoneOwner: Bool = false
    var cacheService: CacheService?
    var cacheInitError: AppStateError?

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

    private func hasCompletePersistedSession() -> Bool {
        defaults.bool(forKey: Self.hasSessionKey)
            && defaults.string(forKey: Self.profileIDKey) != nil
            && defaults.string(forKey: Self.familyIDKey) != nil
            && defaults.string(forKey: Self.zoneNameKey) != nil
            && defaults.string(forKey: Self.zoneOwnerKey) != nil
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let hasSession = defaults.bool(forKey: Self.hasSessionKey)
        // A completed onboarding that lacks a session means we should probe
        // for a recoverable family (restore / reconnect); a brand-new install
        // goes straight to the discovery state so RootView renders the
        // scanning placeholder rather than bouncing through restoringSession.
        authStatus = hasSession ? .restoringSession : .checkingCloudData

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
            authStatus = .checkingCloudData
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
            try await ActiveFamilyScopeGuard.requireServerAuthenticatedIdentity(
                profile: profile,
                family: familyResult,
                zoneID: zoneID,
                isOwner: isOwner,
                cloudKit: cloudKit
            )

            familyZoneID = zoneID
            isZoneOwner = isOwner
            family = familyResult
            currentProfile = profile

            authStatus = .authenticated
        } catch {
            logger.error("Session restoration failed: \(error, privacy: .private)")
            if error is ScopeViolation {
                // The CloudKit-fetched session could not be re-authenticated for
                // this iCloud account. Try restoring from the local cache before
                // wiping state and falling through to discovery — the cache may
                // still have a viable offline session from a prior successful sync.
                if restoreFromCache(profileRecordName: profileRecordName, familyRecordName: familyRecordName, zoneID: zoneID, isOwner: isOwner) {
                    return
                }
                clearSessionAndCloudKitScope(cloudKit: cloudKit)
                authStatus = .checkingCloudData
                await discoverExistingCloudState(cloudKit: cloudKit)
                return
            }
            // Non-`.notFound` / `.invalidArguments` / `.zoneNotFound` errors on the
            // owner path are treated as transient only after a zone-reachability
            // probe confirms the zone itself is still alive. Heroes skip the
            // probe — their zone is in the shared DB, where `fetchShareParticipants`
            // (private-DB only) cannot serve as a reachability signal.
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
                // Try cache fallback BEFORE wiping the session — on a cold
                // launch the zone may be valid but simply hasn't synced to
                // this device yet, so the reachability probe can legitimately
                // fail even when valid cache data exists.
                if restoreFromCache(profileRecordName: profileRecordName, familyRecordName: familyRecordName, zoneID: zoneID, isOwner: isOwner) {
                    // Cache restored — session is back, no need to wipe.
                } else {
                    logger.info("Unrecoverable CloudKit session error and no cache available — clearing session and running cloud discovery")
                    clearSessionAndCloudKitScope(cloudKit: cloudKit)
                    authStatus = .checkingCloudData
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

        familyZoneID = zoneID
        isZoneOwner = isOwner
        family = cachedFamily.toFamily(zoneID: zoneID)
        currentProfile = cachedProfile.toProfile(zoneID: zoneID)
        authStatus = .authenticated
        logger.info("Session restored from local cache (offline mode)")
        // A cache hit implies a prior successful sync; stamp the
        // family/profile freshness gates so the first launch after
        // a transient CloudKit failure does not re-fetch them.
        cache.markCacheFresh(familyRecordName: familyRecordName, type: .family)
        cache.markCacheFresh(familyRecordName: familyRecordName, type: .profile)
        return true
    }

    /// Probes the family zone for reachability. A success confirms the zone
    /// is alive, so the original fetch error is treated as transient. Bounded
    /// by `AppConstants.Session.zoneCheckTimeoutSeconds` so a hung CloudKit
    /// daemon cannot stall cold launch.
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
                   let userRecordID,
                   foundFamily.creatorUserRecordName == userRecordID.recordName
                   || foundFamily.createdBy.recordName == userRecordID.recordName
                {
                    do {
                        let familyRef = CKRecord.Reference(recordID: foundFamily.id, action: .none)
                        let profiles: [Profile] = try await cloudKit.query(
                            Profile.self,
                            predicate: NSPredicate(format: "family == %@", familyRef),
                            in: zone.zoneID,
                            using: db
                        )
                        let matchingProfiles = profiles.filter {
                            $0.isActive
                                && $0.role == .guildMaster
                                && $0.family.recordID == foundFamily.id
                                && $0.creatorUserRecordName == userRecordID.recordName
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

            // Only adopt a profile whose server-authenticated identity
            // matches the current user. When the current user ID cannot be
            // resolved (nil), the helper returns no matches and this shared
            // zone is skipped — never fall back to an arbitrary active
            // profile, which could adopt another user's session.
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
            // Heroes have no private-zone proof of individual membership.
            // A kicked-out hero could still see the shared zone during
            // share-revocation propagation and would otherwise incorrectly
            // adopt another active hero's profile if we fell back to an
            // identity-free scan here. Respect the strict filter's 0-match
            // result and fall through to onboarding so the user must
            // re-accept a fresh share from the GM.
        }
        return candidates
    }

    private func fetchSharedZonesWithBoundedRetry(
        cloudKit: any CloudKitServiceProtocol
    ) async -> [CKRecordZone] {
        do {
            let sharedZones = try await cloudKit.fetchSharedZones()
            logger.info("Initial shared zones check: \(sharedZones.count) shared zones")

            // If empty on cold launch (reinstall), perform a brief retry pulse
            // to allow the CloudKit daemon to sync accepted shares. A hard
            // failure on the first attempt (503 / rate-limited) falls through
            // the outer catch and returns [] — no retries are issued against
            // a throttling response.
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

    /// Active `Profile` records in a shared zone bound to the current iCloud
    /// user — the hero-role recovery signal used by session discovery and by
    /// the hero onboarding reconnect probe. Fail-closed: a nil `userRecordID`
    /// (identity unresolved) returns no matches, and a zone whose profile
    /// query throws is skipped entirely. An arbitrary active profile is never
    /// returned, because that could hand one user another's session.
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
                    || creatorUserRecordName == CKCurrentUserDefaultName
                    || creatorUserRecordName == "_defaultOwner_"
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
                  || serverProfile.creatorUserRecordName == CKCurrentUserDefaultName
                  || serverProfile.creatorUserRecordName == "_defaultOwner_",
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
        familyZoneID = zoneID
        isZoneOwner = isOwner
        self.family = family
        currentProfile = profile
        cloudKit.activeFamilyZoneID = zoneID
        cloudKit.activeIsOwner = isOwner
        authStatus = .authenticated
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

    /// Sign-out is device-local only: it never authors a CloudKit flag and
    /// never touches the family data — it wipes the persisted session (and the
    /// previous family's cache), resets CloudKit scope / CKSyncEngine state,
    /// and resets to `.onboarding`.
    ///
    /// Recovery is discovery-driven, not sign-out-driven. On the next full app
    /// launch the session keys read false, so `AppState.init` starts in
    /// `.checkingCloudData` and `restoreSession` falls through to
    /// `discoverExistingCloudState`, which re-finds the user's private/shared
    /// zone and lands on `.detectedPreviousFamily` (reconnect) whenever the
    /// family and profile still exist — only falling back to `.onboarding`
    /// (Welcome) when nothing recoverable remains. `signOutAndDiscover` runs
    /// that same recovery immediately for the in-session case instead of
    /// waiting for the next launch.
    func signOut(cloudKit: (any CloudKitServiceProtocol)? = nil, syncCoordinator: CKSyncEngineCoordinator? = nil) {
        if let cloudKit {
            clearSessionAndCloudKitScope(cloudKit: cloudKit, syncCoordinator: syncCoordinator)
        } else {
            clearSession()
        }
    }

    /// In-session sign-out: wipes the local session and CloudKit scope (via
    /// `clearSessionAndCloudKitScope()`, which also purges the previous family's cache),
    /// flips to `.checkingCloudData` — the state `discoverExistingCloudState`'s opening
    /// guard requires — and immediately re-runs cloud discovery. If a recoverable family/profile
    /// still exists in iCloud, discovery re-sets `authStatus` to
    /// `.detectedPreviousFamily(...)` (rendering `DetectedFamilyView`); if not,
    /// it falls through to `.onboarding` (`WelcomeView`). This covers the
    /// in-session case, complementing the cold-relaunch recovery that happens on
    /// the next launch. The brief `.checkingCloudData` window during discovery
    /// is hidden by the root view's existing `ProgressView` rendering.
    func signOutAndDiscover(cloudKit: any CloudKitServiceProtocol, syncCoordinator: CKSyncEngineCoordinator? = nil) async {
        if isDiscoveryInFlight {
            logger.info("Sign-out discovered ongoing discovery; cancelling in-flight waiters and deferring completion")
            let waiters = discoveryWaiters
            discoveryWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            return
        }
        clearSessionAndCloudKitScope(cloudKit: cloudKit, syncCoordinator: syncCoordinator)
        authStatus = .checkingCloudData // flip to state discoverExistingCloudState requires
        await discoverExistingCloudState(cloudKit: cloudKit)
    }

    /// Resets the in-memory session state back to the onboarding root. Called
    /// by `clearSession()` after the persisted session and family cache are
    /// wiped. Never touches CloudKit data — recovery is handled by the
    /// discovery path documented on `signOut()` / `signOutAndDiscover()`.
    private func signOutInternal() {
        authStatus = .onboarding
        currentProfile = nil
        family = nil
        familyZoneID = nil
        isZoneOwner = false
    }
}
