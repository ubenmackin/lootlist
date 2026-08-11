//
//  AppState.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import os

@MainActor
@Observable
final class AppState {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "Security")

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
            case let .cacheInitializationFailed(message):
                "Failed to initialize the local cache: \(message)"
            }
        }
    }

    var authStatus: AuthStatus

    var currentProfile: Profile? {
        didSet {
            QuickActionManager.updateQuickActions(for: currentProfile?.role)
        }
    }

    func updateCurrentProfileFromCache() {
        guard let currentID = currentProfile?.id,
              let zoneID = familyZoneID,
              let cache = cacheService,
              let cached = cache.fetchProfile(recordName: currentID.recordName)
        else { return }

        let updated = cached.toProfile(zoneID: zoneID)

        // Compare the FULL cached profile, not a field subset. A cross-device
        // change to payoutPolicy, payoutDay, or customAvatarImageData must
        // propagate to currentProfile exactly like an XP/level/name/avatar
        // change — the hero dashboard and treasury read these fields from
        // currentProfile and would otherwise stay stale indefinitely.
        guard updated != currentProfile else { return }
        logger.info("Updating currentProfile from cache (XP: \(self.currentProfile?.xp ?? 0) -> \(updated.xp), Level: \(self.currentProfile?.level ?? 0) -> \(updated.level))")
        currentProfile = updated
    }

    var pendingQuickAction: QuickActionType?

    var pendingNotificationRoute: NotificationRoute?

    var family: Family?

    var familyZoneID: CKRecordZone.ID?
    var isZoneOwner: Bool = false
    var activeShareURL: URL?
    var cacheService: CacheService?
    var cacheInitError: AppStateError?

    @ObservationIgnored
    private var quickActionTask: Task<Void, Never>?

    @ObservationIgnored
    private var notificationRouteTask: Task<Void, Never>?

    // MARK: - Session Persistence Keys

    private static let profileIDKey = "session_profileRecordName"
    private static let familyIDKey = "session_familyRecordName"
    private static let zoneNameKey = "session_familyZoneName"
    private static let zoneOwnerKey = "session_familyZoneOwnerName"
    private static let isOwnerKey = "session_isZoneOwner"
    private static let hasSessionKey = "session_hasActiveSession"
    private static let abandonedZoneIDsKey = "session_abandonedFamilyZoneNames"

    init() {
        let hasSession = UserDefaults.standard.bool(forKey: Self.hasSessionKey)
        authStatus = hasSession ? .restoringSession : .checkingCloudData

        quickActionTask = Task { @MainActor [weak self] in
            for await notification in NotificationCenter.default.notifications(named: .quickActionTriggered) {
                if let action = notification.object as? QuickActionType {
                    self?.pendingQuickAction = action
                }
            }
        }

        notificationRouteTask = Task { @MainActor [weak self] in
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
            UserDefaults.standard.stringArray(forKey: Self.abandonedZoneIDsKey) ?? []
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.abandonedZoneIDsKey)
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
        let defaults = UserDefaults.standard
        defaults.set(profile.id.recordName, forKey: Self.profileIDKey)
        defaults.set(family.id.recordName, forKey: Self.familyIDKey)
        defaults.set(zoneID.zoneName, forKey: Self.zoneNameKey)
        defaults.set(zoneID.ownerName, forKey: Self.zoneOwnerKey)
        defaults.set(isOwner, forKey: Self.isOwnerKey)
        defaults.set(true, forKey: Self.hasSessionKey)
    }

    func clearSession() {
        let defaults = UserDefaults.standard

        // Purge the previous family's cache before its record name is wiped
        // below. sign-out → sign-into-different-family must not leave the
        // previous family's rows behind for the new family to read.
        if let previousFamilyRecordName = defaults.string(forKey: Self.familyIDKey) {
            cacheService?.purgeFamily(recordName: previousFamilyRecordName)
        }

        defaults.removeObject(forKey: Self.profileIDKey)
        defaults.removeObject(forKey: Self.familyIDKey)
        defaults.removeObject(forKey: Self.zoneNameKey)
        defaults.removeObject(forKey: Self.zoneOwnerKey)
        defaults.removeObject(forKey: Self.isOwnerKey)
        defaults.removeObject(forKey: Self.hasSessionKey)
        signOutInternal()
    }

    func restoreSession(cloudKit: any CloudKitServiceProtocol) async {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.hasSessionKey),
              let profileRecordName = defaults.string(forKey: Self.profileIDKey),
              let familyRecordName = defaults.string(forKey: Self.familyIDKey),
              let zoneName = defaults.string(forKey: Self.zoneNameKey),
              let zoneOwnerName = defaults.string(forKey: Self.zoneOwnerKey)
        else {
            authStatus = .checkingCloudData
            await discoverExistingCloudState(cloudKit: cloudKit)
            return
        }

        let isOwner = defaults.bool(forKey: Self.isOwnerKey)
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: zoneOwnerName)

        cloudKit.activeFamilyZoneID = zoneID
        cloudKit.activeIsOwner = isOwner
        let db = cloudKit.database(isOwner: isOwner)

        let profileID = CKRecord.ID(recordName: profileRecordName, zoneID: zoneID)
        let familyID = CKRecord.ID(recordName: familyRecordName, zoneID: zoneID)

        do {
            async let fetchedProfile = cloudKit.fetch(Profile.self, id: profileID, using: db)
            async let fetchedFamily = cloudKit.fetch(Family.self, id: familyID, using: db)
            let (profile, familyResult) = try await (fetchedProfile, fetchedFamily)

            familyZoneID = zoneID
            isZoneOwner = isOwner
            family = familyResult
            currentProfile = profile

            if isOwner {
                activeShareURL = try? await cloudKit.fetchOrCreateShareURL(in: zoneID, rootRecordID: familyID)
            } else {
                activeShareURL = nil
            }

            authStatus = .authenticated
        } catch {
            logger.error("Session restoration failed: \(error, privacy: .private)")
            if let ckErr = error as? CloudKitServiceError, case .notFound = ckErr {
                clearSession()
            } else {
                // Network error — try cache fallback for offline launch
                if let cache = cacheService,
                   let cachedProfile = cache.fetchProfile(recordName: profileRecordName),
                   let cachedFamily = cache.fetchFamily(recordName: familyRecordName)
                {
                    familyZoneID = zoneID
                    isZoneOwner = isOwner
                    // Restore Profile and Family from cache
                    family = cachedFamily.toFamily(zoneID: zoneID)
                    currentProfile = cachedProfile.toProfile(zoneID: zoneID)
                    authStatus = .authenticated
                    logger.info("Session restored from local cache (offline mode)")
                } else {
                    authStatus = .offlineEmptyCache
                }
            }
        }
    }

    // MARK: - Cloud State Discovery

    // CloudKit discoverability logic requires branching over known containers; refactoring would be a behavioral change outside lint scope.
    // swiftlint:disable:next cyclomatic_complexity
    func discoverExistingCloudState(cloudKit: any CloudKitServiceProtocol) async {
        guard authStatus == .checkingCloudData else { return }

        logger.info("Starting iCloud family discovery...")
        let userRecordID = try? await cloudKit.currentUserRecordID()
        logger.info("Current user record ID: \(userRecordID?.recordName ?? "nil", privacy: .private)")

        do {
            let privateZones = try await cloudKit.fetchPrivateZones()
            logger.info("Found \(privateZones.count) private zones")
            let customZones = privateZones.filter { $0.zoneID.zoneName != "_defaultZone" && $0.zoneID.zoneName != "LootListZone" }

            for zone in customZones {
                logger.info("Inspecting private custom zone: '\(zone.zoneID.zoneName, privacy: .private)'")
                let db = cloudKit.privateDatabase

                var family: Family?

                let familyID = CKRecord.ID(recordName: zone.zoneID.zoneName, zoneID: zone.zoneID)
                if let fetched: Family = try? await cloudKit.fetch(Family.self, id: familyID, using: db) {
                    family = fetched
                    logger.info("Direct point lookup found Family: '\(fetched.name, privacy: .private)'")
                }

                if family == nil {
                    do {
                        let families: [Family] = try await cloudKit.query(Family.self, predicate: NSPredicate(value: true), in: zone.zoneID, using: db)
                        family = families.first
                        logger.info("Query fallback returned \(families.count) Family records.")
                    } catch {
                        logger.error("Query fallback error for zone '\(zone.zoneID.zoneName, privacy: .private)': \(error, privacy: .private)")
                    }
                }

                if let foundFamily = family {
                    var profile: Profile?

                    let creatorID = CKRecord.ID(recordName: foundFamily.createdBy.recordName, zoneID: zone.zoneID)
                    if let fetchedProfile: Profile = try? await cloudKit.fetch(Profile.self, id: creatorID, using: db), fetchedProfile.isActive {
                        profile = fetchedProfile
                        logger.info("Direct point lookup found active Guild Master profile: '\(fetchedProfile.displayName, privacy: .private)'")
                    }

                    if profile == nil {
                        do {
                            let profiles: [Profile] = try await cloudKit.query(Profile.self, predicate: NSPredicate(value: true), in: zone.zoneID, using: db)
                            logger.info("Profile query returned \(profiles.count) Profile records.")
                            profile = profiles.first(where: { $0.role == .guildMaster && $0.isActive }) ?? profiles.first(where: { $0.isActive })
                        } catch {
                            logger.error("Profile query error for zone '\(zone.zoneID.zoneName, privacy: .private)': \(error, privacy: .private)")
                        }
                    }

                    if let activeProfile = profile {
                        logger.info("SUCCESS: Detected Guild Master profile '\(activeProfile.displayName, privacy: .private)' in family '\(foundFamily.name, privacy: .private)'")
                        authStatus = .detectedPreviousFamily(family: foundFamily, profile: activeProfile, zoneID: zone.zoneID, isOwner: true)
                        return
                    }
                }
            }
        } catch {
            logger.error("Error fetching private zones: \(error, privacy: .private)")
        }

        do {
            var sharedZones = try await cloudKit.fetchSharedZones()
            logger.info("Initial shared zones check: \(sharedZones.count) shared zones")

            // If empty on cold launch (reinstall), perform a brief retry pulse to allow CloudKit daemon to sync accepted shares
            if sharedZones.isEmpty {
                for attempt in 1 ... AppConstants.Sync.maxPulseAttempts {
                    logger.info("Shared zone sync pulse attempt \(attempt)...")
                    try? await Task.sleep(nanoseconds: AppConstants.Sync.pulseDelayNanoseconds)
                    sharedZones = await (try? cloudKit.fetchSharedZones()) ?? []
                    if !sharedZones.isEmpty {
                        logger.info("Shared zone sync pulse succeeded! Found \(sharedZones.count) shared zones.")
                        break
                    }
                }
            }

            logger.info("Final shared zones count: \(sharedZones.count)")

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
                logger.info("Shared zone '\(zone.zoneID.zoneName, privacy: .private)' returned \(activeProfiles.count) matching Profile records.")

                if let activeHeroProfile = activeProfiles.first,
                   let family = await Self.sharedZoneFamily(cloudKit: cloudKit, zoneID: zone.zoneID)
                {
                    logger.info("SUCCESS: Detected Hero profile '\(activeHeroProfile.displayName, privacy: .private)' in shared family '\(family.name, privacy: .private)'")
                    authStatus = .detectedPreviousFamily(family: family, profile: activeHeroProfile, zoneID: zone.zoneID, isOwner: false)
                    return
                }
            }
        } catch {
            logger.error("Error fetching shared zones: \(error, privacy: .private)")
        }

        logger.info("Discovery complete — no active family detected. Transitioning to onboarding.")
        authStatus = .onboarding
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

        let profiles = await (try? cloudKit.query(
            Profile.self,
            predicate: NSPredicate(value: true),
            in: zoneID,
            using: cloudKit.sharedDatabase
        )) ?? []

        return profiles.filter { $0.isActive && $0.iCloudUserID.recordName == userRecordID?.recordName }
    }

    /// The `Family` record in a shared zone: a direct point lookup on the
    /// zone-named record first, with a full-zone query as fallback when the
    /// point lookup misses. Returns nil when neither path resolves a family.
    static func sharedZoneFamily(
        cloudKit: any CloudKitServiceProtocol,
        zoneID: CKRecordZone.ID
    ) async -> Family? {
        let familyID = CKRecord.ID(recordName: zoneID.zoneName, zoneID: zoneID)
        if let family = try? await cloudKit.fetch(Family.self, id: familyID, using: cloudKit.sharedDatabase) {
            return family
        }

        let families = await (try? cloudKit.query(
            Family.self,
            predicate: NSPredicate(value: true),
            in: zoneID,
            using: cloudKit.sharedDatabase
        )) ?? []
        return families.first
    }

    func acceptDetectedFamily(family: Family, profile: Profile, zoneID: CKRecordZone.ID, isOwner: Bool, cloudKit: any CloudKitServiceProtocol) async {
        saveSession(profile: profile, family: family, zoneID: zoneID, isOwner: isOwner)
        familyZoneID = zoneID
        isZoneOwner = isOwner
        self.family = family
        currentProfile = profile
        cloudKit.activeFamilyZoneID = zoneID
        cloudKit.activeIsOwner = isOwner
        if isOwner {
            do {
                activeShareURL = try await cloudKit.fetchOrCreateShareURL(in: zoneID, rootRecordID: family.id)
            } catch {
                logger.error("Failed to generate share URL on accept: \(error, privacy: .private)")
            }
        }
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
        clearSession()
    }

    var shareInviteItems: [Any] {
        let name = family?.name ?? "our guild"
        if let activeShareURL {
            let message = "Join \(name) on LootList! Tap the link to join our guild:\n\(activeShareURL.absoluteString)"
            return [message]
        } else {
            let message = "Join \(name) on LootList!"
            return [message]
        }
    }

    /// Sign-out is device-local only: it never authors a CloudKit flag and
    /// never touches the family data — it wipes the persisted session (and the
    /// previous family's cache) and resets to `.onboarding`.
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
    func signOut() {
        clearSession()
    }

    /// In-session sign-out: wipes the local session (via `clearSession()`, which
    /// also purges the previous family's cache), flips to `.checkingCloudData`
    /// — the state `discoverExistingCloudState`'s opening guard requires — and
    /// immediately re-runs cloud discovery. If a recoverable family/profile
    /// still exists in iCloud, discovery re-sets `authStatus` to
    /// `.detectedPreviousFamily(...)` (rendering `DetectedFamilyView`); if not,
    /// it falls through to `.onboarding` (`WelcomeView`). This covers the
    /// in-session case, complementing the cold-relaunch recovery that happens on
    /// the next launch. The brief `.checkingCloudData` window during discovery
    /// is hidden by the root view's existing `ProgressView` rendering.
    func signOutAndDiscover(cloudKit: any CloudKitServiceProtocol) async {
        clearSession() // wipes UserDefaults, purges family cache
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
        activeShareURL = nil
    }
}
