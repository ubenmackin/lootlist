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
    private let questService: QuestService

    var cacheService: CacheService?

    var cloudKitReference: any CloudKitServiceProtocol {
        cloudKit
    }

    let toastManager: ToastManager?

    /// Keys of immediate profile refreshes currently in flight, formatted as
    /// `"<operation>|<familyRecordName>"`. Actor-isolated dedupe guard: when a
    /// genuinely-required immediate refresh for the same operation + family is
    /// already running, concurrent callers collapse onto it instead of issuing
    /// duplicate CloudKit queries that race SyncEngine's push-driven incremental
    /// sync and duplicate server-derived writes.
    private let refreshInFlightKeys = Mutex<Set<String>>([])

    /// The current user's CloudKit record ID, resolved lazily and cached so an
    /// onboarding flow resolves the identity exactly once. CloudKit identities
    /// are immutable for a signed-in user within a session, so the cached value
    /// stays valid for the lifetime of the service. Serves the onboarding
    /// dedupe flows (`createFamily`, `joinFamilyViaAcceptedShare`) only — the
    /// security-relevant owner-anchor check (`isFamilyOwner`) deliberately
    /// bypasses this cache and re-resolves the identity on every call so an
    /// OS-level iCloud account change without an app relaunch cannot authorize
    /// operations against a stale pre-switch identity.
    private var cachedUserRecordID: CKRecord.ID?

    init(cloudKit: any CloudKitServiceProtocol, appState: AppState, questService: QuestService, cacheService: CacheService? = nil, toastManager: ToastManager? = nil) {
        self.cloudKit = cloudKit
        self.appState = appState
        self.questService = questService
        self.cacheService = cacheService
        self.toastManager = toastManager
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
        return (family: session.family, profile: session.profile)
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
        // their own profile. Routine updates stay push-driven via SyncEngine.
        await refreshProfilesFromCloudKit(for: family)

        progressHandler?("Joined Guild!", 1.0)
        return JoinedFamilyResult(
            family: family,
            profile: savedProfile,
            didReuseActiveProfile: didReuseActiveProfile
        )
    }

    // MARK: - Role & Membership Management

    /// Cache-first read. A fresh cache is served as-is;
    /// background updates flow through SyncEngine's push-driven pipeline, so no
    /// ad-hoc CloudKit refresh is issued on the cache-hit path. A stale or
    /// partial cache falls through to a single synchronous CloudKit query that
    /// write-throughs the cache.
    func fetchHeroes(for family: Family) async throws -> [Profile] {
        if let cache = cacheService {
            let familyName = family.id.recordName
            let cached = cache.fetchProfiles(family: familyName)
                .filter { $0.role == UserRole.hero.rawValue && $0.isActive }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            if !cached.isEmpty, cache.isCacheFresh(familyRecordName: familyName, type: .profile) {
                return cached.map { $0.toProfile(zoneID: cloudKit.resolvedZoneID) }
            }
        }
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let predicate = NSPredicate(format: "family == %@", familyRef)
        let all = try await cloudKit.query(Profile.self, predicate: predicate)
        cacheService?.upsertProfiles(all)
        return all
            .filter { $0.role == .hero && $0.isActive }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Cache-first read. A fresh cache is served as-is;
    /// background updates flow through SyncEngine's push-driven pipeline, so no
    /// ad-hoc CloudKit refresh is issued on the cache-hit path. A stale or
    /// partial cache falls through to a single synchronous CloudKit query that
    /// write-throughs the cache.
    func fetchAllProfilesForFamily(_ family: Family) async throws -> [Profile] {
        if let cache = cacheService {
            let familyName = family.id.recordName
            let cached = cache.fetchProfiles(family: familyName)
            if !cached.isEmpty, cache.isCacheFresh(familyRecordName: familyName, type: .profile) {
                return cached.map { $0.toProfile(zoneID: cloudKit.resolvedZoneID) }
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
        let all = try await cloudKit.query(Profile.self, predicate: predicate)
        cacheService?.upsertProfiles(all)
        return all.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive {
                return lhs.isActive && !rhs.isActive
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    func updateMemberRole(profile: Profile, newRole: UserRole) async throws {
        // Privileged mutation: only the owner anchor (server-authenticated
        // family owner) may promote, demote, or reassign a member's role.
        // Legacy families without an owner anchor fall back to the parent-role
        // check (Guild Master / Ranger).
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

        var updated = profile
        updated.role = newRole

        let name = profile.id.recordName
        let snapshot = cacheService?.fetchProfiles(family: profile.family.recordID.recordName)
            .first(where: { $0.recordName == name })
        let preMutationChangeTag = snapshot?.changeTag
        // changeTag rehydrated from cache row per toX(zoneID:), safe for use in ConcurrentEditDetector.
        let snapshotProfile: Profile? = snapshot?.toProfile(zoneID: cloudKit.resolvedZoneID)

        // Register the optimistic window so a background sync skips this row.
        let registry = cacheService?.inFlightRegistry
        await registry?.register(name)

        cacheService?.upsertProfile(updated)
        if appState.currentProfile?.id == updated.id {
            appState.currentProfile = updated
        }

        let (zoneID, db) = familyContext(for: profile.family.recordID)
        do {
            let saved = try await cloudKit.save(updated, in: zoneID, using: db)
            cacheService?.upsertProfile(saved)
            if appState.currentProfile?.id == saved.id {
                appState.currentProfile = saved
            }
            await registry?.deregister(name)
        } catch {
            await OptimisticFailureHandler.handleSaveFailure(
                recordID: profile.id,
                preMutationChangeTag: preMutationChangeTag,
                snapshot: snapshotProfile,
                cloudKit: cloudKit,
                toastManager: toastManager,
                fetchCurrentTag: { self.cacheService?.fetchProfile(recordName: name)?.changeTag },
                upsert: { restored in
                    self.cacheService?.upsertProfile(restored)
                    if self.appState.currentProfile?.id == restored.id {
                        self.appState.currentProfile = restored
                    }
                },
                invalidate: { _ in self.cacheService?.invalidateProfile(recordName: name) },
                error: error,
                db: db
            )
            await registry?.deregister(name)
            throw FamilyServiceError.persistenceFailed
        }
    }

    func leaveFamily(profile: Profile) async throws {
        await unassignActiveQuests(for: profile)
        try await deactivateProfile(profile)

        // Best-effort removal of the leaver's own share participant entry. Only
        // the zone owner can mutate a `CKShare` participant list, and the family
        // zone lives in the owner's private database — so for a non-owner leave
        // this resolves against the leaver's own databases and either silently
        // no-ops (no shares found there) or fails server-side. The profile
        // deactivation above is the authoritative leave; the owner-side share
        // reconciler and Invitations panel observe the departed identity still
        // on the share and surface it for owner-side revocation.
        let family = await family(for: profile)
        let rootRecordID = family?.id ?? profile.family.recordID
        do {
            try await cloudKit.removeParticipant(iCloudUserRecordName: profile.iCloudUserID.recordName, from: rootRecordID)
        } catch {
            logger.error("Failed to remove leaving member's share participant: \(error, privacy: .private)")
        }
    }

    @discardableResult
    func kickMember(profile: Profile) async throws -> FamilyKickResult {
        // Privileged mutation: removing a member from the guild is reserved for
        // the owner anchor (server-authenticated family owner). Legacy families
        // without an owner anchor fall back to the parent-role check.
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
        await unassignActiveQuests(for: profile)
        try await deactivateProfile(profile)

        // Revoke the kicked member's share access so a deactivated profile
        // cannot keep reading the shared zone. Best-effort: the deactivation
        // above is the authoritative kick and already succeeded, so a failed
        // revocation here must NOT throw (that would imply the kick itself
        // rolled back). Surface the partial outcome to the caller via
        // `FamilyKickResult.partialRevocationFailed` so the Guild Master is
        // told their share access persists and can revoke it from the
        // Invitations panel.
        let rootRecordID = family.id
        do {
            try await cloudKit.removeParticipant(iCloudUserRecordName: profile.iCloudUserID.recordName, from: rootRecordID)
            return .fully
        } catch {
            logger.error("Failed to remove kicked member's share participant: \(error, privacy: .private)")
            return .partialRevocationFailed(
                error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }

    /// Deactivates a member profile whose CloudKit share access was revoked at
    /// the access layer — used by the share-reconciliation observer when a
    /// participant is removed out-of-band (e.g. through the system share
    /// sheet), which the app's `Profile` records do not observe directly.
    /// Best-effort: a failure leaves the profile active and is logged
    /// privately; the in-app membership list stays as-is until a later
    /// reconciliation pass reconciles it.
    func deactivateMemberAfterShareRevocation(_ profile: Profile) async throws {
        try await deactivateProfile(profile)
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
            if let userRecordID = try? await cloudKit.currentUserRecordID() {
                return userRecordID.recordName == anchor
            }
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
    private func resolveCurrentUserRecordID() async throws -> CKRecord.ID {
        if let cachedUserRecordID {
            return cachedUserRecordID
        }
        let userRecordID: CKRecord.ID
        do {
            userRecordID = try await cloudKit.currentUserRecordID()
        } catch {
            throw FamilyServiceError.accountUnavailable
        }
        cachedUserRecordID = userRecordID
        return userRecordID
    }

    /// Resolves the Family for a member profile (cache-first, then CloudKit) so
    /// owner-anchor authorization can be evaluated without threading a `family`
    /// parameter through `updateMemberRole` / `kickMember`. Returns nil when the
    /// family cannot be resolved — callers treat that as unauthorized.
    private func family(for profile: Profile) async -> Family? {
        let familyID = profile.family.recordID
        if let cached = cacheService?.fetchFamily(recordName: familyID.recordName) {
            return cached.toFamily(zoneID: cloudKit.resolvedZoneID)
        }
        let (_, db) = familyContext(for: familyID)
        return try? await cloudKit.fetch(Family.self, id: familyID, using: db)
    }

    /// Immediately re-queries a family's profiles from CloudKit and
    /// write-throughs the cache via this service's own write path. Deduped by
    /// an actor-isolated in-flight guard keyed by operation + family, so
    /// concurrent callers collapse to a single query instead of racing
    /// SyncEngine's push-driven incremental sync with duplicate
    /// server-derived writes. Reserved for the few places where an
    /// immediate refresh is genuinely required (e.g. joining a family via
    /// share link) — routine background updates belong to SyncEngine, and
    /// stale cache-first reads already fall through to the synchronous query
    /// in `fetchHeroes`/`fetchAllProfilesForFamily`. Internal so tests can
    /// exercise the in-flight dedupe.
    func refreshProfilesFromCloudKit(for family: Family) async {
        let key = "profiles|\(family.id.recordName)"
        let alreadyInFlight = refreshInFlightKeys.withLock { keys -> Bool in
            if keys.contains(key) {
                return true
            }
            keys.insert(key)
            return false
        }
        guard !alreadyInFlight else { return }
        defer { refreshInFlightKeys.withLock { _ = $0.remove(key) } }

        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let predicate = NSPredicate(format: "family == %@", familyRef)
        if let fresh = try? await cloudKit.query(Profile.self, predicate: predicate) {
            cacheService?.upsertProfiles(fresh)
        }
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

    private func unassignActiveQuests(for profile: Profile) async {
        guard let family = appState.family else { return }
        let payoutDay = profile.payoutDay ?? family.payoutDay
        let currentWeek = WeekMath.startOfWeek(for: Date(), payoutDay: payoutDay)

        #if DEBUG
            let questStart = QuestService.startOfWeek(for: Date(), payoutDay: payoutDay)
            assert(
                currentWeek == questStart,
                "QuestService.startOfWeek and WeekMath.startOfWeek diverged: \(currentWeek) vs \(questStart)"
            )
        #endif

        let currentQuests = await (try? questService.fetchActiveQuests(profile: profile, weekOf: currentWeek)) ?? []
        let nextWeek = Calendar.iso8601UTC.date(byAdding: .weekOfYear, value: 1, to: currentWeek) ?? currentWeek
        let nextQuests = await (try? questService.fetchActiveQuests(profile: profile, weekOf: nextWeek)) ?? []

        for quest in currentQuests + nextQuests {
            try? await questService.unassignQuest(quest)
        }
    }

    func familyContext(for _: CKRecord.ID) -> (zone: CKRecordZone.ID, db: CKDatabase?) {
        let zoneID = cloudKit.resolvedZoneID // already set with correct ownerName
        let db = cloudKit.database(isOwner: appState.isZoneOwner)
        return (zoneID, db)
    }

    private func deactivateProfile(_ profile: Profile) async throws {
        // Privileged mutation: a parent may deactivate any member. A member may
        // only deactivate their own profile (self-service leave); deactivating
        // another member's profile is parent-only.
        let actingProfile = appState.currentProfile
        let isSelfDeactivation = actingProfile?.id == profile.id
        guard isSelfDeactivation || actingProfile?.role.isParent == true else {
            throw FamilyServiceError.unauthorized
        }

        var updated = profile
        updated.isActive = false

        let name = profile.id.recordName
        let snapshot = cacheService?.fetchProfiles(family: profile.family.recordID.recordName)
            .first(where: { $0.recordName == name })
        let preMutationChangeTag = snapshot?.changeTag
        // changeTag rehydrated from cache row per toX(zoneID:), safe for use in ConcurrentEditDetector.
        let snapshotProfile: Profile? = snapshot?.toProfile(zoneID: cloudKit.resolvedZoneID)

        // Register the optimistic window so a background sync skips this row.
        let registry = cacheService?.inFlightRegistry
        await registry?.register(name)

        cacheService?.upsertProfile(updated)
        if appState.currentProfile?.id == updated.id {
            appState.currentProfile = updated
        }

        let (zoneID, db) = familyContext(for: profile.family.recordID)
        do {
            let saved = try await cloudKit.save(updated, in: zoneID, using: db)
            cacheService?.upsertProfile(saved)
            if appState.currentProfile?.id == saved.id {
                appState.currentProfile = saved
            }
            await registry?.deregister(name)
        } catch {
            await OptimisticFailureHandler.handleSaveFailure(
                recordID: profile.id,
                preMutationChangeTag: preMutationChangeTag,
                snapshot: snapshotProfile,
                cloudKit: cloudKit,
                toastManager: toastManager,
                fetchCurrentTag: { self.cacheService?.fetchProfile(recordName: name)?.changeTag },
                upsert: { restored in
                    self.cacheService?.upsertProfile(restored)
                    if self.appState.currentProfile?.id == restored.id {
                        self.appState.currentProfile = restored
                    }
                },
                invalidate: { _ in self.cacheService?.invalidateProfile(recordName: name) },
                error: error,
                db: db
            )
            await registry?.deregister(name)
            throw FamilyServiceError.persistenceFailed
        }
    }

    func deleteFamilyAndReset(family: Family) async throws {
        // Privileged mutation: irreversible — deleting the family is reserved
        // for the owner anchor (server-authenticated family owner). Legacy
        // families without an owner anchor fall back to the zone-owner +
        // parent-role check.
        let isOwner = await isFamilyOwner(family)
        let actingRoleIsParent = appState.currentProfile?.role.isParent ?? false
        let isAuthorized: Bool = if let anchor = family.creatorUserRecordName, anchor != "__defaultOwner__", anchor != "_defaultOwner_" {
            isOwner
        } else {
            appState.isZoneOwner && actingRoleIsParent
        }
        guard isAuthorized else {
            throw FamilyServiceError.unauthorized
        }
        // 1. Delete the CloudKit zone if this user owns it, or add to abandoned queue if offline.
        if let zoneID = appState.familyZoneID {
            do {
                try await cloudKit.deleteZone(zoneID)
            } catch {
                logger.error("Could not delete zone immediately; queueing abandoned zone: \(error, privacy: .private)")
                appState.addAbandonedZoneID(zoneID.zoneName)
            }
        }

        // 2. Clear CloudKit active state.
        cloudKit.activeFamilyZoneID = nil
        cloudKit.activeIsOwner = true

        // 3. Purge this family's local SwiftData cache.  Fall back to a
        //    global clearAll() only if the family recordName is unavailable.
        let familyRecordName = family.id.recordName
        if !familyRecordName.isEmpty {
            cacheService?.purgeFamily(recordName: familyRecordName)
        } else if let cacheService {
            try cacheService.clearAll()
        }

        appState.clearSession()
    }
}
