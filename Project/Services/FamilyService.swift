//
//  FamilyService.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import os
import Synchronization

enum FamilyServiceError: Error, LocalizedError, Equatable, Sendable {
    case invalidInviteCode
    case joinFailed
    case creationFailed
    case persistenceFailed
    case accountUnavailable
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .invalidInviteCode:
            "This invitation code is invalid."
        case .joinFailed:
            "Could not join the family. Please try again."
        case .creationFailed:
            "Could not create the family. Please try again."
        case .persistenceFailed:
            "Could not save your changes. Please try again."
        case .accountUnavailable:
            "Your iCloud account is unavailable. Sign in and try again."
        case .unauthorized:
            "You don't have permission to do that."
        }
    }
}

/// Outcome of removing a member from the guild. The profile deactivation is
/// the authoritative kick and always succeeds; the share-access revocation is
/// best-effort and may fail, which the Guild Master must be told about so the
/// lingering access can be revoked from the Invitations panel.
enum FamilyKickResult: Equatable, Sendable {
    /// Member removed and their share access revoked.
    case fully
    /// Member removed from the roster, but their share access could not be
    /// revoked — the Guild Master should revoke the lingering access from the
    /// Invitations panel.
    case partialRevocationFailed(error: String)
}

// MARK: - Protocol for testable injection into ViewModels

@MainActor
protocol FamilyProfileFetching: Sendable {
    func fetchAllProfilesForFamily(_ family: Family) async throws -> [Profile]
}

/// The owner-family session result consumed by the onboarding flow: the
/// resolved `Family` and the Guild Master `Profile`. Backs both the brand-new
/// and reused-family paths of `createFamily`.
struct OwnerSessionResult {
    let family: Family
    let profile: Profile
}

/// The joiner session result consumed by the onboarding flow: the resolved
/// `Family` and the joined `Profile`, plus a flag marking whether the join
/// reused an existing ACTIVE profile as-is. When `didReuseActiveProfile` is
/// true the profile's identity was preserved untouched, so the caller must
/// skip any onboarding displayName/avatar writes; only the reactivation and
/// fresh-mint branches (flag false) take those values.
struct JoinedFamilyResult {
    let family: Family
    let profile: Profile
    let didReuseActiveProfile: Bool
}

// MARK: - FamilyService

@MainActor
@Observable
final class FamilyService: FamilyProfileFetching {
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "Security")

    let cloudKit: any CloudKitServiceProtocol
    let appState: AppState
    let questService: QuestService

    var cacheService: CacheService? {
        didSet {
            questService.cacheService = cacheService
        }
    }

    var syncCoordinator: CKSyncEngineCoordinator?

    var cloudKitReference: any CloudKitServiceProtocol {
        cloudKit
    }

    let toastManager: ToastManager?

    /// Bootstrap seeder for default achievements. Injected when available;
    /// when nil an ephemeral `AchievementService` is built from the current
    /// `cacheService`/`syncCoordinator`/`appState` at seeding time so tests
    /// using the legacy initializer still seed idempotently.
    var achievementService: AchievementService?

    /// Optional collaborators for hero bootstrap seeding. When not injected the
    /// join path falls back to direct cache + sync coordination so legacy
    /// initializers continue to seed without additional wiring.
    var notificationService: NotificationService?
    var treasuryService: TreasuryService?

    /// Guards allowance period seeding against concurrent duplicate minting for
    /// the same hero week, mirroring the settlement mutex used in
    /// TreasuryService to avoid duplicate period races.
    private let allowancePeriodSeedMutex = Mutex<Set<String>>([])

    /// Keys of immediate profile refreshes currently in flight, formatted as
    /// `"<operation>|<familyRecordName>"`. Actor-isolated dedupe guard: when a
    /// genuinely-required immediate refresh for the same operation + family is
    /// already running, concurrent callers collapse onto it instead of issuing
    /// duplicate CloudKit queries that race CKSyncEngine's push-driven sync
    /// and duplicate server-derived writes.
    private let refreshInFlightKeys = Mutex<Set<String>>([])

    /// The current user's CloudKit record ID, resolved lazily and cached so an
    /// onboarding flow resolves the identity exactly once. CloudKit identities
    /// are immutable for a signed-in user within a session, so the cached value
    /// stays valid for the lifetime of the service. Serves the onboarding
    /// checks (`checkForExistingFamily`, `findOwnedFamily`) without repeated
    /// network round-trips to `CKContainer.fetchUserRecordID()`.
    ///
    /// Coalesced via `Task` caching: concurrent callers share the same
    /// in-flight `currentUserRecordID()` fetch instead of issuing duplicate
    /// network calls. Two concurrent `resolveCurrentUserRecordID()` invocations
    /// that both observe `nil` coalesce onto the single stored
    /// `Task<CKRecord.ID, Error>`; a flaky-network failure in one of two raced
    /// fetches cannot spuriously throw `accountUnavailable` when the other
    /// succeeded. On failure the cached task is cleared so a later retry can
    /// re-resolve. Protected by a `Mutex` around the task reference so the
    /// check-then-create is atomic. This cache is **private to onboarding
    /// dedupe** — the security-relevant owner-anchor check (`isFamilyOwner`)
    /// deliberately bypasses it and re-resolves `cloudKit.currentUserRecordID()`
    /// fresh on every call so an OS-level iCloud account switch without an app
    /// relaunch can never be masked by a stale pre-switch identity.
    private final class CachedUserRecordIDTaskBox: @unchecked Sendable {
        let task: Task<CKRecord.ID, any Error>
        init(_ task: Task<CKRecord.ID, any Error>) {
            self.task = task
        }
    }

    private let cachedUserRecordIDTaskMutex = Mutex<CachedUserRecordIDTaskBox?>(nil)

    init(
        cloudKit: any CloudKitServiceProtocol,
        appState: AppState,
        questService: QuestService,
        cacheService: CacheService? = nil,
        toastManager: ToastManager? = nil,
        syncCoordinator: CKSyncEngineCoordinator? = nil,
        achievementService: AchievementService? = nil,
        notificationService: NotificationService? = nil,
        treasuryService: TreasuryService? = nil
    ) {
        self.cloudKit = cloudKit
        self.appState = appState
        self.questService = questService
        self.cacheService = cacheService
        if let cacheService {
            questService.cacheService = cacheService
        }
        self.toastManager = toastManager
        self.syncCoordinator = syncCoordinator
        self.achievementService = achievementService
        self.notificationService = notificationService
        self.treasuryService = treasuryService
    }

    // MARK: - Family Creation (Guild Master Flow)

    @discardableResult
    func createFamily(name: String,
                      ownerProfile: Profile) async throws -> (family: Family, profile: Profile)
    {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw FamilyServiceError.creationFailed
        }

        let familyID = CKRecord.ID(recordName: UUID().uuidString)
        let zoneID = CKRecordZone.ID(zoneName: familyID.recordName,
                                     ownerName: CKCurrentUserDefaultName)

        // Step 1: Parent-side dedupe BEFORE ensuring the candidate zone — if
        // this iCloud user already owns a family, reuse it rather than minting a
        // duplicate. Run before `ensureZoneExists` because the reuse path already
        // has a zone; an early ensure would orphan an empty custom zone on every
        // re-onboarding. Fail-closed: a transient lookup failure throws rather
        // than falling through and minting a duplicate.
        let currentUserRecordName = try await resolveCurrentUserRecordID().recordName
        let existingOwner: (family: Family, zoneID: CKRecordZone.ID)?
        do {
            existingOwner = try await findExistingOwnerFamily(currentUserRecordName: currentUserRecordName)
        } catch {
            throw FamilyServiceError.creationFailed
        }
        if let existing = existingOwner {
            // Reuse path: do NOT `ensureZoneExists` (would orphan an empty zone on
            // every re-onboarding). Resolve/recreate the GM in the existing zone;
            // existing profile values preserved, not overwritten from `ownerProfile`.
            let existingZoneID = existing.zoneID
            let existingFamily = existing.family
            let resolvedOwner: Profile
            do {
                resolvedOwner = try await resolveExistingOwnerProfile(
                    in: existingZoneID,
                    family: existingFamily,
                    ownerProfile: ownerProfile
                )
            } catch {
                throw FamilyServiceError.creationFailed
            }
            cacheService?.upsertFamily(existingFamily)
            cacheService?.upsertProfile(resolvedOwner)

            let session = finalizeOwnerSession(family: existingFamily,
                                               profile: resolvedOwner,
                                               zoneID: existingZoneID)
            await seedDefaultAchievements(for: session.family)
            return (family: session.family, profile: session.profile)
        }

        // Brand-new path: zone is actually used (post-dedupe), never orphaned.
        do {
            try await cloudKit.ensureZoneExists(zoneID)
        } catch {
            throw FamilyServiceError.creationFailed
        }

        var family = Family(name: name,
                            createdBy: ownerProfile.id,
                            id: familyID)

        let pvtDB = cloudKit.privateDatabase

        do {
            family = try await cloudKit.save(family, in: zoneID, using: pvtDB)
            cacheService?.upsertFamily(family)
        } catch {
            throw FamilyServiceError.creationFailed
        }

        var owner = ownerProfile
        owner.role = .guildMaster
        owner.family = CKRecord.Reference(recordID: family.id, action: .none)
        owner.isActive = true

        let savedOwner: Profile
        do {
            savedOwner = try await cloudKit.save(owner, in: zoneID, using: pvtDB)
            cacheService?.upsertProfile(savedOwner)
        } catch {
            throw FamilyServiceError.creationFailed
        }

        // Share minting deferred to the GM's first role-specific invitation.
        let session = finalizeOwnerSession(family: family,
                                           profile: savedOwner,
                                           zoneID: zoneID)
        await seedDefaultAchievements(for: session.family)
        return (family: session.family, profile: session.profile)
    }

    // MARK: - Achievement Seeding

    /// Best-effort bootstrap of default achievements after family creation.
    /// Idempotent: `AchievementService` checks `cache.isCacheFresh` and
    /// CloudKit for existing definitions before enqueuing saves, using the
    /// deterministic recordName `<familyRecordName>-<requirementRawValue>`.
    private func seedDefaultAchievements(for family: Family) async {
        if let achievementService {
            try? await achievementService.seedDefaultAchievements(family: family)
            return
        }
        // Ephemeral seeder when not injected (tests / legacy init).
        let seeder = AchievementService(
            cloudKit: cloudKit,
            cacheService: cacheService,
            appState: appState,
            syncCoordinator: syncCoordinator
        )
        try? await seeder.seedDefaultAchievements(family: family)
    }

    // MARK: - Join Family (Joiner Flow via CKShare Link)

    /// `metadata` is optional only for tests (`CKShare.Metadata` cannot be
    /// synthesized in this SDK); production callers always pass a resolved value.
    /// `displayName`/`avatarClass` are written by the fresh-mint and reactivation
    /// branches, preserved by the active-reuse branch. `didReuseActiveProfile`
    /// flags whether the caller must skip overwriting identity fields. The role
    /// is decoded from the share title, not passed in, so one path serves all roles.
    func joinFamilyViaAcceptedShare(metadata: CKShare.Metadata?,
                                    displayName: String?,
                                    avatarClass: AvatarClass?,
                                    progressHandler: ((String, Double) -> Void)? = nil) async throws -> JoinedFamilyResult
    {
        logger.info("Joining family via accepted share started. hasMetadata=\(metadata != nil)")
        // Step 1: Accept the share. `metadata` is nil only for tests; production
        // callers always resolve it before joining.
        if let metadata {
            progressHandler?("Accepting family invitation...", 0.4)
            logger.info("Invoking cloudKit.acceptShare(metadata)...")
            do {
                try await cloudKit.acceptShare(metadata: metadata)
                logger.info("Accept family share succeeded.")
            } catch {
                logger.error("Accept family share failed: \(error, privacy: .private)")
                // Preserve the underlying error (which carries the symbolic
                // `CKError.Code`) so the caller can surface an
                // invalid-or-expired-invitation message for the not-found codes
                // instead of losing the classification behind a generic wrapper.
                throw error
            }
        }

        // Step 2: Discover shared zones. Fetched unconditionally because the
        // metadata-absent test fallback needs `.first`; production derives the
        // zone from the metadata root ID instead (a user can belong to several
        // shared families, and zone-list order is not family-specific).
        progressHandler?("Connecting to family Guild...", 0.65)
        logger.info("Fetching shared zones from cloudKit...")
        let sharedZones: [CKRecordZone]
        do {
            sharedZones = try await cloudKit.fetchSharedZones()
            logger.info("Found \(sharedZones.count) shared zones.")
        } catch {
            logger.error("Fetching shared zones failed: \(error, privacy: .private)")
            throw FamilyServiceError.joinFailed
        }

        let sharedDB = cloudKit.sharedDatabase

        // Step 3: Point-lookup the Family by ID (no query index required).
        // Zone and record name both derive from the metadata's
        // `hierarchicalRootRecordID`, targeting the exact family accepted; only
        // the metadata-absent test path falls back to `.first` + `"root"`.
        let metadataRoot: CKRecord.ID? = metadata?.hierarchicalRootRecordID
        let family: Family
        let zoneID: CKRecordZone.ID
        let rootRecordID: CKRecord.ID
        if let metadataRoot {
            zoneID = metadataRoot.zoneID
            rootRecordID = metadataRoot
        } else {
            guard let familyZone = sharedZones.first else {
                throw FamilyServiceError.joinFailed
            }
            zoneID = familyZone.zoneID
            rootRecordID = CKRecord.ID(recordName: "root")
        }
        let sharedFamilyID = CKRecord.ID(
            recordName: rootRecordID.recordName,
            zoneID: zoneID
        )

        do {
            family = try await cloudKit.fetch(Family.self, id: sharedFamilyID, using: sharedDB)
            cacheService?.upsertFamily(family)
        } catch {
            throw FamilyServiceError.joinFailed
        }

        // Identity dedupe: resolve the current user and look up an existing
        // profile (any role). Both are fail-closed — `accountUnavailable` for an
        // unavailable iCloud account, `joinFailed` for a transient lookup error.
        progressHandler?("Setting up your Hero profile...", 0.85)
        let userRecordID = try await resolveCurrentUserRecordID()

        let existingProfile: Profile?
        do {
            existingProfile = try await findExistingProfileForCurrentUser(
                in: zoneID,
                family: family,
                currentUserRecordID: userRecordID
            )
        } catch {
            throw FamilyServiceError.joinFailed
        }

        // Role is decoded from the share title, not passed in. An unrecognized or
        // legacy title falls back to `.hero` — recoverable, the GM can re-invite.
        let decodedRole = UserRole.fromShareTitle(metadata?.share[CKShare.SystemFieldKey.title] as? String) ?? .hero

        let savedProfile: Profile
        let didReuseActiveProfile: Bool
        if let existing = existingProfile, existing.isActive {
            // Active match: reuse as-is, do not overwrite identity fields.
            logger.info("Rejoining existing active profile \(existing.displayName, privacy: .private) (record \(existing.id.recordName, privacy: .private))")
            savedProfile = existing
            didReuseActiveProfile = true
        } else if let existing = existingProfile {
            // Inactive match: reactivate, applying onboarding display name/avatar
            // and updating role to match the decoded invitation share role.
            var reactivated = existing
            reactivated.isActive = true
            reactivated.role = decodedRole
            reactivated.family = CKRecord.Reference(recordID: family.id, action: .none)
            if let displayName {
                reactivated.displayName = displayName.trimmingCharacters(in: .whitespaces)
            }
            if let avatarClass {
                reactivated.avatarClass = avatarClass
            }
            do {
                savedProfile = try await cloudKit.save(reactivated, in: zoneID, using: sharedDB)
                logger
                    .info(
                        "Reactivating inactive profile \(savedProfile.displayName, privacy: .private) with role '\(decodedRole.displayName)' (record \(savedProfile.id.recordName, privacy: .private))"
                    )
            } catch {
                throw FamilyServiceError.persistenceFailed
            }
            didReuseActiveProfile = false
        } else {
            // No match: mint a fresh profile with the decoded role.
            let profile = Profile(
                displayName: displayName?.trimmingCharacters(in: .whitespaces) ?? "",
                avatarClass: avatarClass,
                role: decodedRole,
                iCloudUserID: userRecordID,
                family: CKRecord.Reference(recordID: family.id, action: .none)
            )

            do {
                savedProfile = try await cloudKit.save(profile, in: zoneID, using: sharedDB)
            } catch {
                throw FamilyServiceError.joinFailed
            }
            didReuseActiveProfile = false
        }
        cacheService?.upsertProfile(savedProfile)

        appState.familyZoneID = zoneID
        appState.isZoneOwner = false
        cloudKit.activeFamilyZoneID = zoneID
        cloudKit.activeIsOwner = false
        appState.saveSession(profile: savedProfile, family: family, zoneID: zoneID, isOwner: false)

        // Immediate roster refresh — the joiner's cache only has the Family +
        // their own profile. Routine updates stay push-driven via CKSyncEngine.
        await refreshProfilesFromCloudKit(for: family)

        // Defense-in-depth: re-apply the locally saved profile after the
        // refresh. The CloudKit query may return a stale copy (e.g. the
        // profile was just minted with a placeholder displayName that the
        // server hasn't yet overwritten with the real name). Ensuring the
        // locally-known-correct profile is never evicted from the cache
        // during the join flow prevents a later `updateCurrentProfileFromCache`
        // from merging an empty displayName into `appState.currentProfile`.
        cacheService?.upsertProfile(savedProfile)

        // Hero bootstrap: seed per-hero defaults so the new member has a
        // complete local state before the first sync round trips.
        await seedNotificationPreferences(for: savedProfile, family: family)
        await seedAllowancePeriod(for: savedProfile, family: family)

        progressHandler?("Joined Guild!", 1.0)
        return JoinedFamilyResult(
            family: family,
            profile: savedProfile,
            didReuseActiveProfile: didReuseActiveProfile
        )
    }

    // MARK: - Role & Membership Management

    /// Cache-first read. A fresh cache is served as-is;
    /// background updates flow through CKSyncEngine's push-driven pipeline, so no
    /// ad-hoc CloudKit refresh is issued on the cache-hit path. A stale or
    /// partial cache falls through to a single synchronous CloudKit query that
    /// write-throughs the cache.
    func fetchHeroes(for family: Family) async throws -> [Profile] {
        if let cache = cacheService {
            let familyName = family.id.recordName
            let allProfiles = cache.fetchProfiles(family: familyName)
            if cache.isCacheFresh(familyRecordName: familyName, type: .profile) {
                return allProfiles
                    .filter { $0.role == UserRole.hero.rawValue && $0.isActive }
                    .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                    .map { $0.toProfile(zoneID: family.id.zoneID) }
            }
        }
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let predicate = NSPredicate(format: "family == %@", familyRef)
        let isOwner = (family.id.recordName == appState.family?.id.recordName)
            ? appState.isZoneOwner
            : (family.id.zoneID.ownerName == CKCurrentUserDefaultName)
        let db = cloudKit.database(isOwner: isOwner)
        let all = try await cloudKit.query(Profile.self, predicate: predicate, in: family.id.zoneID, using: db)
        cacheService?.upsertProfiles(all)
        return all
            .filter { $0.role == .hero && $0.isActive }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Cache-first read. A fresh cache is served as-is;
    /// background updates flow through CKSyncEngine's push-driven pipeline, so no
    /// ad-hoc CloudKit refresh is issued on the cache-hit path. A stale or
    /// partial cache falls through to a single synchronous CloudKit query that
    /// write-throughs the cache.
    func fetchAllProfilesForFamily(_ family: Family) async throws -> [Profile] {
        if let cache = cacheService {
            let familyName = family.id.recordName
            let cached = cache.fetchProfiles(family: familyName)
            if cache.isCacheFresh(familyRecordName: familyName, type: .profile) {
                return cached.map { $0.toProfile(zoneID: family.id.zoneID) }
                    .sorted { lhs, rhs in
                        if lhs.isActive != rhs.isActive {
                            return lhs.isActive && !rhs.isActive
                        }
                        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                    }
            }
        }

        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let predicate = NSPredicate(format: "family == %@", familyRef)
        let isOwner = (family.id.recordName == appState.family?.id.recordName)
            ? appState.isZoneOwner
            : (family.id.zoneID.ownerName == CKCurrentUserDefaultName)
        let db = cloudKit.database(isOwner: isOwner)
        let all = try await cloudKit.query(Profile.self, predicate: predicate, in: family.id.zoneID, using: db)
        cacheService?.upsertProfiles(all)
        return all.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive {
                return lhs.isActive && !rhs.isActive
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    func requireParentOrOwner(for profile: Profile) async throws -> Family {
        let family = await family(for: profile)
        guard let family else {
            throw FamilyServiceError.unauthorized
        }
        if family.creatorUserRecordName != nil {
            guard await isFamilyOwner(family) else {
                throw FamilyServiceError.unauthorized
            }
        } else {
            guard let acting = appState.currentProfile, acting.role.isParent else {
                throw FamilyServiceError.unauthorized
            }
        }
        return family
    }

    func updateMemberRole(profile: Profile, newRole: UserRole) async throws {
        // Privileged mutation: only the owner anchor (server-authenticated
        // family owner) may promote, demote, or reassign a member's role.
        // Legacy families without an owner anchor fall back to the parent-role
        // check (Guild Master / Ranger).
        _ = try await requireParentOrOwner(for: profile)

        var updated = profile
        updated.role = newRole

        cacheService?.upsertProfile(updated)
        if appState.currentProfile?.id == updated.id {
            appState.currentProfile = updated
        }
        let isOwner = appState.isZoneOwner
        syncCoordinator?.enqueueSave(recordID: updated.id, isOwner: isOwner)
    }

    // MARK: - Private Helpers

    /// Server-authenticated owner check, anchored on CloudKit's read-only
    /// `creatorUserRecordID`. Returns false when the creator is unresolved
    /// (nil) — callers handle the nil (legacy) case.
    func isFamilyOwner(_ family: Family) async -> Bool {
        if let anchor = family.creatorUserRecordName,
           anchor != "__defaultOwner__",
           anchor != "_defaultOwner_"
        {
            // Owner-anchor authorization is security-relevant, so the identity
            // is re-resolved FRESH on every call instead of consulting the
            // per-session cache: an OS-level iCloud account change without an
            // app relaunch must never be masked by a stale cached identity
            // (which would authorize the pre-switch user's owner-gated
            // operations). Deny-by-default when resolution fails.
            do {
                let userRecordID = try await cloudKit.currentUserRecordID()
                return userRecordID.recordName == anchor
            } catch {
                logger.warning("Could not resolve current user for owner check: \(error, privacy: .private)")
                return false
            }
        }
        // Legacy fallback: require supplied family zone matches active zone
        guard family.id.zoneID == appState.familyZoneID else {
            return false
        }
        return appState.isZoneOwner
    }

    /// Resolves the current user's CloudKit record ID exactly once per session,
    /// caching it so the onboarding dedupe flows (`createFamily`,
    /// `joinFamilyViaAcceptedShare`) resolve the identity a single time instead of
    /// re-issuing the network round-trip on each lookup. The
    /// security-relevant owner-anchor check (`isFamilyOwner`) does NOT use this
    /// helper — it re-resolves `cloudKit.currentUserRecordID()` fresh on every
    /// call so an OS-level iCloud account change cannot be masked by a stale
    /// cached identity. Throws `FamilyServiceError.accountUnavailable` when
    /// CloudKit cannot resolve the identity so callers can surface the
    /// iCloud-account failure to the user.
    ///
    /// Concurrency: coalesced via `Task` caching. The stored
    /// `Task<CKRecord.ID, Error>` is guarded by `cachedUserRecordIDTaskMutex`
    /// so two concurrent onboarding callers cannot both create a fetch. The
    /// second caller awaits the first caller's in-flight task rather than
    /// issuing a second network request; a failure in one of two raced fetches
    /// cannot spuriously throw `accountUnavailable` when the other succeeded.
    /// A failed task is cleared so a later retry can re-resolve.
    private func resolveCurrentUserRecordID() async throws -> CKRecord.ID {
        if let existingBox = cachedUserRecordIDTaskMutex.withLock({ $0 }) {
            do {
                return try await existingBox.task.value
            } catch {
                cachedUserRecordIDTaskMutex.withLock { current in
                    if current === existingBox {
                        current = nil
                    }
                }
                throw FamilyServiceError.accountUnavailable
            }
        }
        let newTask = Task<CKRecord.ID, any Error> {
            try await cloudKit.currentUserRecordID()
        }
        let newBox = CachedUserRecordIDTaskBox(newTask)
        let boxToAwait: CachedUserRecordIDTaskBox = cachedUserRecordIDTaskMutex.withLock { current in
            if let existing = current {
                return existing
            }
            current = newBox
            return newBox
        }
        if boxToAwait !== newBox {
            newTask.cancel()
            do {
                return try await boxToAwait.task.value
            } catch {
                cachedUserRecordIDTaskMutex.withLock { current in
                    if current === boxToAwait {
                        current = nil
                    }
                }
                throw FamilyServiceError.accountUnavailable
            }
        }
        do {
            return try await boxToAwait.task.value
        } catch {
            cachedUserRecordIDTaskMutex.withLock { current in
                if current === boxToAwait {
                    current = nil
                }
            }
            throw FamilyServiceError.accountUnavailable
        }
    }

    /// Resolves the Family for a member profile (cache-first, then CloudKit) so
    /// owner-anchor authorization can be evaluated without threading a `family`
    /// parameter through `updateMemberRole` / `kickMember`. Returns nil when the
    /// family cannot be resolved — callers treat that as unauthorized.
    func family(for profile: Profile) async -> Family? {
        let familyID = profile.family.recordID
        if let cached = cacheService?.fetchFamily(recordName: familyID.recordName) {
            return cached.toFamily(zoneID: familyID.zoneID)
        }
        let (_, db) = familyContext(for: familyID)
        do {
            return try await cloudKit.fetch(Family.self, id: familyID, using: db)
        } catch {
            logger.warning("Failed to fetch family for profile authorization: \(error, privacy: .private)")
            return nil
        }
    }

    /// Immediately re-queries a family's profiles from CloudKit and
    /// write-throughs the cache via this service's own write path. Deduped by
    /// an actor-isolated in-flight guard keyed by operation + family, so
    /// concurrent callers collapse to a single query instead of racing
    /// CKSyncEngine's push-driven sync with duplicate
    /// server-derived writes. Reserved for the few places where an
    /// immediate refresh is genuinely required (e.g. joining a family via
    /// share link) — routine background updates belong to CKSyncEngine, and
    /// stale cache-first reads already fall through to the synchronous query
    /// in `fetchHeroes`/`fetchAllProfilesForFamily`. Internal so tests can
    /// exercise the in-flight dedupe.
    func refreshProfilesFromCloudKit(for family: Family) async {
        let key = "profiles|\(family.id.recordName)"
        let alreadyInFlight = refreshInFlightKeys.withLock {
            if $0.contains(key) {
                return true
            }; $0.insert(key); return false
        }
        guard !alreadyInFlight else { return }
        defer { refreshInFlightKeys.withLock { _ = $0.remove(key) } }

        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let predicate = NSPredicate(format: "family == %@", familyRef)
        let isOwner = (family.id.recordName == appState.family?.id.recordName)
            ? appState.isZoneOwner
            : (family.id.zoneID.ownerName == CKCurrentUserDefaultName)
        let db = cloudKit.database(isOwner: isOwner)
        do {
            let fresh = try await cloudKit.query(Profile.self, predicate: predicate, in: family.id.zoneID, using: db)
            cacheService?.upsertProfiles(fresh)
        } catch {
            logger.warning("Failed to refresh profiles from CloudKit: \(error, privacy: .private)")
        }
    }

    // MARK: - Hero Bootstrap Seeding

    /// Seeds per-hero notification preferences for the newly joined profile.
    /// Each `NotificationEventType` receives a deterministic record so the
    /// seed is idempotent across retries and devices; existing rows are left
    /// untouched so a user's prior opt-out is never clobbered.
    private func seedNotificationPreferences(for profile: Profile, family: Family) async {
        guard let cacheService else { return }
        let familyRecordName = family.id.recordName
        let profileRecordName = profile.id.recordName
        let zoneID = family.id.zoneID
        var missing: [NotificationPreference] = []
        missing.reserveCapacity(NotificationEventType.allCases.count)
        for event in NotificationEventType.allCases {
            let deterministicName = "\(familyRecordName)-\(profileRecordName)-\(event.rawValue)"
            // Idempotent gate: skip when a row already exists in the local cache.
            if cacheService.fetchNotificationPreference(
                profileRecordName: profileRecordName,
                familyRecordName: familyRecordName,
                eventType: event.rawValue
            ) != nil {
                continue
            }
            // Also avoid duplicating a cached row under the alternative pref- prefix
            // that older seeds may have written for the same event.
            let altName = "pref-\(profileRecordName)-\(familyRecordName)-\(event.rawValue)"
            if cacheService.fetchNotificationPreference(recordName: altName, family: familyRecordName) != nil
                || cacheService.fetchNotificationPreference(recordName: deterministicName, family: familyRecordName) != nil
            {
                continue
            }
            let recordID = CKRecord.ID(recordName: deterministicName, zoneID: zoneID)
            let pref = NotificationPreference(
                profile: CKRecord.Reference(recordID: profile.id, action: .none),
                eventType: event,
                enabled: true,
                family: CKRecord.Reference(recordID: family.id, action: .none),
                id: recordID
            )
            missing.append(pref)
        }
        guard !missing.isEmpty else { return }
        // Batch upsert mirrors BackgroundCacheActor.batchUpsertNotificationPreferences
        // to keep the write off the per-row save path.
        cacheService.upsertNotificationPreferences(missing, family: familyRecordName)
        let isOwner = appState.isZoneOwner
        for pref in missing {
            syncCoordinator?.enqueueSave(recordID: pref.id, isOwner: isOwner)
        }
    }

    /// Seeds the active allowance period for the current week for the new hero.
    /// Uses the payout-day-aware week anchor so the period matches the week
    /// bucket treasury reads use. The deterministic period name makes the
    /// write idempotent, and a lightweight in-flight mutex prevents concurrent
    /// join retries from racing to create the same period.
    private func seedAllowancePeriod(for profile: Profile, family: Family) async {
        // Prefer the injected treasury when available so the period creation
        // shares its single-flight and authorization checks.
        let payoutDay = profile.payoutDay ?? family.payoutDay
        let startOfWeek = WeekMath.startOfWeek(for: Date(), payoutDay: payoutDay)
        let weekInt = Int(startOfWeek.timeIntervalSince1970)
        let recordName = "period-\(family.id.recordName)-\(profile.id.recordName)-\(weekInt)"
        let alreadyInFlight = allowancePeriodSeedMutex.withLock { $0.contains(recordName) }
        guard !alreadyInFlight else { return }
        allowancePeriodSeedMutex.withLock { _ = $0.insert(recordName) }
        defer { allowancePeriodSeedMutex.withLock { _ = $0.remove(recordName) } }

        if let treasuryService {
            // Treasury path already handles cache and enqueue with its own mutex.
            _ = try? await treasuryService.getOrCreateAllowancePeriod(profile: profile, weekOf: startOfWeek, family: family)
            return
        }

        guard let cacheService else { return }
        if cacheService.fetchAllowancePeriod(recordName: recordName, family: family.id.recordName) != nil {
            return
        }
        let period = AllowancePeriod(
            weekOf: startOfWeek,
            profile: CKRecord.Reference(recordID: profile.id, action: .none),
            questsTotal: 0,
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: recordName, zoneID: family.id.zoneID)
        )
        cacheService.upsertAllowancePeriod(period)
        let isOwner = appState.isZoneOwner
        syncCoordinator?.enqueueSave(recordID: period.id, isOwner: isOwner)
    }

    /// Looks up the joining user's existing `Profile` (any role) within the
    /// joined shared zone so a re-join can reactivate rather than duplicate.
    /// The predicate keys on `iCloudUserID + family` — never `displayName`, which is
    /// user-editable and not unique — so the match is anchored on the
    /// server-authenticated CloudKit identity scoped to this family. Returns the
    /// first active profile (reactivation path), else the first profile overall
    /// (inactive-reactivate branch), else nil when the user has no profile here yet.
    func findExistingProfileForCurrentUser(in zoneID: CKRecordZone.ID,
                                           family: Family,
                                           currentUserRecordID: CKRecord.ID) async throws -> Profile?
    {
        // `iCloudUserID` is stored as a plain record-name String
        // (`Profile.toRecord()`), so the query constant must be a String — only
        // the `family` field is a CKRecord.Reference.
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let predicate = NSPredicate(format: "family == %@ AND iCloudUserID == %@", familyRef, currentUserRecordID.recordName)
        let matches = try await cloudKit.query(Profile.self,
                                               predicate: predicate,
                                               in: zoneID,
                                               using: cloudKit.sharedDatabase)
        return matches.first(where: { $0.isActive }) ?? matches.first
    }

    func familyContext(for recordID: CKRecord.ID) -> (zone: CKRecordZone.ID, db: CKDatabase?) {
        let zoneID = recordID.zoneID
        let isOwner = (recordID.zoneID.ownerName == CKCurrentUserDefaultName) || (appState.family?.id.recordName == recordID.recordName && appState.isZoneOwner)
        let db = cloudKit.database(isOwner: isOwner)
        return (zoneID, db)
    }
}
