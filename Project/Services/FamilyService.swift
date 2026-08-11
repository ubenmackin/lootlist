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

// MARK: - Protocol for testable injection into ViewModels

@MainActor
protocol FamilyProfileFetching: Sendable {
    func fetchAllProfilesForFamily(_ family: Family) async throws -> [Profile]
}

/// The owner-family session result consumed by the onboarding flow: the
/// resolved `Family`, the Guild Master `Profile`, and the share URL (nil when
/// share creation failed). Backs both the brand-new and reused-family paths of
/// `createFamily`.
struct OwnerSessionResult {
    let family: Family
    let profile: Profile
    let shareURL: URL?
}

// MARK: - FamilyService

@MainActor
@Observable
final class FamilyService: FamilyProfileFetching {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "Security")

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
    /// dedupe flows (`createFamily`, `joinFamilyViaShare`) only — the
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
                      ownerProfile: Profile) async throws -> (family: Family, profile: Profile, shareURL: URL?) // swiftlint:disable:this large_tuple
    {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw FamilyServiceError.creationFailed
        }

        let familyID = CKRecord.ID(recordName: UUID().uuidString)
        let zoneID = CKRecordZone.ID(zoneName: familyID.recordName,
                                     ownerName: CKCurrentUserDefaultName)

        // Step 1: Parent-side dedupe (run BEFORE ensuring the candidate zone).
        // If this iCloud user already owns a family in one of their private
        // custom zones (e.g. they are re-onboarding after a prior session or
        // sign-out), route them back to the existing guild instead of minting a
        // duplicate Family and Guild Master profile. Mirrors the Hero dedupe in
        // `joinFamilyViaShare` and is likewise fail-closed: the current user's
        // identity resolution is required, and a dedupe lookup that cannot
        // prove there is no existing owner family throws rather than falling
        // through to the brand-new-family branch, so a transient CloudKit
        // failure cannot mint a duplicate Family + Guild Master profile. Only a
        // successful lookup that returns no match proceeds to create a new
        // family. Crucially the candidate zone for the brand-new family is NOT
        // ensured up front: on the reuse path the existing family's zone is
        // already present, and an early `ensureZoneExists` would leave an
        // orphaned empty custom zone in the user's private database on every
        // parent re-onboarding.
        let currentUserRecordName = try await resolveCurrentUserRecordID().recordName
        let existingOwner: (family: Family, zoneID: CKRecordZone.ID)?
        do {
            existingOwner = try await findExistingOwnerFamily(currentUserRecordName: currentUserRecordName)
        } catch {
            throw FamilyServiceError.creationFailed
        }
        if let existing = existingOwner {
            // Branch 1 — the user already owns a family: reuse it. The existing
            // family's zone is already present in the private database, so
            // `ensureZoneExists` is intentionally NOT called on this branch (an
            // orphaned empty zone would accumulate on every re-onboarding
            // otherwise). Resolve — and reactivate-or-create — the Guild Master
            // profile within the EXISTING family's zone so a parent re-onboarding
            // is never a hard failure (mirrors the Hero reactivation branch).
            // Existing profile values (display name, avatar, role overrides) are
            // accepted as-is and are NOT overwritten from the passed-in
            // ownerProfile; a missing GM is minted fresh in the existing zone,
            // never as a duplicate Family. Lookup failures inside the resolver
            // are translated to `creationFailed` so no raw `CloudKitServiceError`
            // escapes `createFamily`.
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

            // shareURL is generated lazily from the existing share (owner path).
            var shareURL: URL?
            do {
                shareURL = try await cloudKit.fetchOrCreateShareURL(in: existingZoneID,
                                                                    rootRecordID: existingFamily.id)
            } catch {
                logger.error("CKShare creation failed for reused family: \(error, privacy: .private)")
            }

            let session = finalizeOwnerSession(family: existingFamily,
                                               profile: resolvedOwner,
                                               zoneID: existingZoneID,
                                               shareURL: shareURL)
            return (family: session.family, profile: session.profile, shareURL: session.shareURL)
        }

        // Step 2: Brand-new family — NOW ensure the candidate zone exists. This
        // is reached only when the dedupe lookup provably found no existing owner
        // family, so the zone is actually going to be used and is never orphaned.
        do {
            try await cloudKit.ensureZoneExists(zoneID)
        } catch {
            throw FamilyServiceError.creationFailed
        }

        var family = Family(name: name,
                            createdBy: ownerProfile.id,
                            id: familyID)

        let pvtDB = cloudKit.privateDatabase

        // Step 3: Save the Family record in the private database.
        do {
            family = try await cloudKit.save(family, in: zoneID, using: pvtDB)
            cacheService?.upsertFamily(family)
        } catch {
            throw FamilyServiceError.creationFailed
        }

        // Step 4: Create a CKShare for the Family record.
        var shareURL: URL?
        do {
            let targetID = CKRecord.ID(recordName: familyID.recordName, zoneID: zoneID)
            shareURL = try await cloudKit.fetchOrCreateShareURL(in: zoneID, rootRecordID: targetID)
        } catch {
            logger.error("CKShare creation failed: \(error, privacy: .private)")
        }

        // Step 5: Save the Guild Master profile in the private database.
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

        // Hand the newly-created Family + Guild Master to the shared session path.
        let session = finalizeOwnerSession(family: family,
                                           profile: savedOwner,
                                           zoneID: zoneID,
                                           shareURL: shareURL)
        return (family: session.family, profile: session.profile, shareURL: session.shareURL)
    }

    // MARK: - Join Family (Hero Flow via CKShare Link)

    /// The metadata is optional because `CKShare.Metadata` cannot be directly
    /// constructed in this SDK (it must come from `CKFetchShareMetadataOperation`
    /// or a platform scene/app-delegate callback). Production callers always
    /// pass a resolved metadata; tests may pass `nil` to drive the hero dedupe
    /// branches, in which case the share accept is skipped and the Family record
    /// is located via the `"root"` fallback below.
    func joinFamilyViaShare(metadata: CKShare.Metadata?,
                            heroProfile: Profile) async throws -> (family: Family, profile: Profile)
    {
        // Hero dedupe on re-join. Before creating a brand-new profile we look up
        // whether this iCloud user already has a hero in the joined zone, then
        // branch on what we find:
        //   1. ACTIVE match exists      → skip the save entirely, reuse its id.
        //   2. INACTIVE match exists    → reactivate it (set active, refresh the
        //      family reference, allow a rename via the passed-in display name).
        //   3. NO match                 → proceed with the brand-new profile.
        // The dedupe is fail-closed: if the hero lookup cannot PROVE there is
        // no existing profile (a transient CloudKit query failure — flaky
        // network, quota, transient server error), we surface the failure to
        // the user to retry rather than falling through to the brand-new-profile
        // branch and minting a duplicate hero for an iCloud user who may already
        // have one in this family. Only a successful lookup that returns no
        // match may proceed to create a new profile. Resolving the joining
        // user's identity is likewise required — an unavailable iCloud account
        // throws `accountUnavailable` rather than silently minting a duplicate
        // hero the user cannot identify with.

        // Step 1: Accept the CKShare. A nil metadata defers to the caller (only
        // tests pass nil); production always resolves metadata before joining.
        if let metadata {
            do {
                try await cloudKit.acceptShare(metadata: metadata)
            } catch {
                throw FamilyServiceError.joinFailed
            }
        }

        // Step 2: Discover the shared zone.
        let sharedZones: [CKRecordZone]
        do {
            sharedZones = try await cloudKit.fetchSharedZones()
        } catch {
            throw FamilyServiceError.joinFailed
        }

        guard let familyZone = sharedZones.first else {
            throw FamilyServiceError.joinFailed
        }

        let sharedDB = cloudKit.sharedDatabase
        let zoneID = familyZone.zoneID

        // Step 3: Fetch the Family record from the shared zone directly by ID (no query index required).
        let family: Family
        let targetRecordID: CKRecord.ID = if #available(iOS 16.0, *) {
            metadata?.hierarchicalRootRecordID ?? CKRecord.ID(recordName: "root")
        } else {
            metadata?.rootRecordID ?? CKRecord.ID(recordName: "root")
        }
        let sharedFamilyID = CKRecord.ID(
            recordName: targetRecordID.recordName,
            zoneID: zoneID
        )

        do {
            family = try await cloudKit.fetch(Family.self, id: sharedFamilyID, using: sharedDB)
            cacheService?.upsertFamily(family)
        } catch {
            throw FamilyServiceError.joinFailed
        }

        // Step 3.5: Hero dedupe — resolve the current user's record ID and look
        // up an existing hero profile in the joined zone so a re-join reactivates
        // rather than duplicates. Both the identity resolution and the lookup are
        // fail-closed: an unavailable iCloud account surfaces as
        // `accountUnavailable`, and a dedupe lookup that cannot prove there is no
        // existing profile (a thrown query error) surfaces as `joinFailed` so the
        // user can retry — the brand-new-profile branch below is reached only when
        // a successful lookup proves no match exists.
        let userRecordID = try await resolveCurrentUserRecordID()

        let existingHero: Profile?
        do {
            existingHero = try await findExistingHeroProfile(
                in: zoneID,
                family: family,
                currentUserRecordID: userRecordID
            )
        } catch {
            throw FamilyServiceError.joinFailed
        }

        // Step 4: Resolve the saved Hero profile, branching on the dedupe result.
        let savedHero: Profile
        if let existing = existingHero, existing.isActive {
            // Branch 1 — ACTIVE match exists: reuse it; do not create a duplicate.
            logger.info("Rejoining existing active Hero \(existing.displayName, privacy: .public) (record \(existing.id.recordName, privacy: .private))")
            savedHero = existing
        } else if let existing = existingHero {
            // Branch 2 — INACTIVE match exists: reactivate it (the user is
            // actively re-onboarding, so allow a rename via the passed-in name).
            var reactivated = existing
            reactivated.isActive = true
            reactivated.family = CKRecord.Reference(recordID: family.id, action: .none)
            reactivated.displayName = heroProfile.displayName.trimmingCharacters(in: .whitespaces)
            do {
                savedHero = try await cloudKit.save(reactivated, in: zoneID, using: sharedDB)
                logger.info("Reactivating inactive Hero \(savedHero.displayName, privacy: .public) (record \(savedHero.id.recordName, privacy: .private))")
            } catch {
                throw FamilyServiceError.persistenceFailed
            }
        } else {
            // Branch 3 — NO match: brand-new Hero profile in the shared zone.
            var hero = heroProfile
            hero.role = .hero
            hero.family = CKRecord.Reference(recordID: family.id, action: .none)
            hero.isActive = true

            do {
                savedHero = try await cloudKit.save(hero, in: zoneID, using: sharedDB)
            } catch {
                throw FamilyServiceError.joinFailed
            }
        }
        cacheService?.upsertProfile(savedHero)

        // Update AppState and CloudKitService with zone participant info.
        appState.familyZoneID = zoneID
        appState.isZoneOwner = false
        appState.activeShareURL = nil
        cloudKit.activeFamilyZoneID = zoneID
        cloudKit.activeIsOwner = false
        appState.saveSession(profile: savedHero, family: family, zoneID: zoneID, isOwner: false)

        // Genuinely-required immediate refresh: the joiner's cache holds only
        // the Family + their own hero so far. Hydrate the roster now (deduped
        // by the in-flight guard) so the hero dashboard shows siblings without
        // waiting for the next push-driven sync. Routine background updates
        // belong to SyncEngine's push-driven pipeline.
        await refreshProfilesFromCloudKit(for: family)

        return (family, savedHero)
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
        if let family, family.creatorUserRecordName != nil {
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
    }

    func kickMember(profile: Profile) async throws {
        // Privileged mutation: removing a member from the guild is reserved for
        // the owner anchor (server-authenticated family owner). Legacy families
        // without an owner anchor fall back to the parent-role check.
        let family = await family(for: profile)
        if let family, family.creatorUserRecordName != nil {
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
    /// `joinFamilyViaShare`) resolve the identity a single time instead of
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

    /// Looks up the joining user's existing hero `Profile` within the joined
    /// shared zone so a re-join can reactivate rather than duplicate. The
    /// predicate keys on `iCloudUserID + family` — never `displayName`, which is
    /// user-editable and not unique — so the match is anchored on the
    /// server-authenticated CloudKit identity scoped to this family. Returns the
    /// first active hero (reactivation path), else the first hero overall
    /// (inactive-reactivate branch), else nil when the user has no hero here yet.
    func findExistingHeroProfile(in zoneID: CKRecordZone.ID,
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

    /// Parent-side dedupe: looks up whether the current user is already the
    /// creator (owner) of a family in one of their private custom zones, so a
    /// re-onboarding Guild Master is routed back to the existing guild instead
    /// of minting a duplicate. Mirrors `AppState.discoverExistingCloudState`:
    /// for each private custom zone (zoneName not `_defaultZone` / `LootListZone`)
    /// it attempts a direct point-lookup of the `Family` whose record name
    /// equals the zone name, then checks the server-stamped
    /// `creatorUserRecordName` (never authored locally) against the current
    /// user. Returns the first matching Family plus its zoneID, or nil when the
    /// user owns no private family zone yet. FAIL-CLOSED: any fetch/query error
    /// (flaky network, quota, transient server error) throws rather than
    /// returning nil, so a caller can never mistake an unresolved lookup for a
    /// provable "no existing family" and mint a duplicate.
    private func findExistingOwnerFamily(currentUserRecordName: String) async throws -> (family: Family, zoneID: CKRecordZone.ID)? {
        let privateZones: [CKRecordZone] = try await cloudKit.fetchPrivateZones()

        let customZones = privateZones.filter { $0.zoneID.zoneName != "_defaultZone" && $0.zoneID.zoneName != "LootListZone" }
        let db = cloudKit.privateDatabase

        for zone in customZones {
            let familyID = CKRecord.ID(recordName: zone.zoneID.zoneName, zoneID: zone.zoneID)
            let family: Family
            do {
                family = try await cloudKit.fetch(Family.self, id: familyID, using: db)
            } catch let error as CloudKitServiceError {
                // Fail-closed per-zone lookup: only a provable absence
                // (`notFound`) means this zone holds no owner family — keep
                // scanning the next candidate. Any other (transient/unknown)
                // fetch error is rethrown so the caller maps it to
                // `creationFailed` rather than branching to the
                // brand-new-family path and minting a duplicate.
                guard case .notFound = error else { throw error }
                continue
            }

            if family.creatorUserRecordName == currentUserRecordName {
                logger.info("Parent dedupe found existing owner family '\(family.name, privacy: .private)' in zone '\(zone.zoneID.zoneName, privacy: .private)'")
                return (family, zone.zoneID)
            }
        }
        return nil
    }

    /// Resolves the existing Guild Master `Profile` for a reused owner family,
    /// reactivating-or-creating one within the EXISTING family's zone so a
    /// parent re-onboarding is never a hard failure (mirrors the Hero
    /// reactivation branch in `joinFamilyViaShare`):
    ///   1. ACTIVE GM exists   → reuse it as-is (no save, no overwrite).
    ///   2. INACTIVE GM exists → reactivate it (set `isActive = true`, re-save).
    ///      Existing profile values (display name, avatar, role overrides) are
    ///      preserved and are NOT overwritten from the passed-in onboarding
    ///      profile — the parent dedupe contract is stricter than the hero one
    ///      (which allows a rename).
    ///   3. NO GM at all       → mint a fresh Guild Master in the EXISTING
    ///      family's zone using the passed-in onboarding profile values, so the
    ///      owner re-onboards against their original family rather than
    ///      minting a duplicate Family.
    /// The lookup mirrors `AppState.discoverExistingCloudState`: a direct
    /// point-lookup on the family's creator first, then a query fallback for any
    /// Guild Master in the zone.
    ///
    /// Fail-closed error contract: only a provable absence
    /// (`CloudKitServiceError.notFound`) from the point-lookup falls through to
    /// the query fallback. Any other lookup failure — point-lookup transient
    /// error OR query error — is translated to `FamilyServiceError.creationFailed`
    /// before it can escape, so no raw `CloudKitServiceError` reaches the caller
    /// of `createFamily`. This matches Architectural Decision 8's "lookup errors
    /// rethrow as creationFailed" contract on BOTH the dedupe-family lookup and
    /// the resolve-profile lookup.
    private func resolveExistingOwnerProfile(in zoneID: CKRecordZone.ID,
                                             family: Family,
                                             ownerProfile ownerOnboarding: Profile) async throws -> Profile
    {
        let db = cloudKit.privateDatabase
        let creatorID = CKRecord.ID(recordName: family.createdBy.recordName, zoneID: zoneID)
        do {
            // `cloudKit.fetch` returns a non-optional `Profile` and throws on
            // absence, so the provable-absence vs error distinction is made in
            // the catch clauses (fail-closed) rather than via `try?` (which
            // would swallow transient errors).
            let fetched: Profile = try await cloudKit.fetch(Profile.self, id: creatorID, using: db)
            if fetched.isActive {
                logger.info("Direct point lookup found active Guild Master profile: '\(fetched.displayName, privacy: .public)'")
                return fetched
            }
            // Branch 2 — INACTIVE GM: reactivate it, preserving the existing
            // identity (display name, avatar, role) rather than overwriting
            // from the onboarding profile.
            logger.info("Direct point lookup found inactive Guild Master profile '\(fetched.displayName, privacy: .public)'; reactivating")
            return try await reactivateOrSaveOwner(fetched, in: zoneID, family: family, using: db)
        } catch let error as CloudKitServiceError {
            // Fail-closed direct lookup: only a provable absence (`notFound`)
            // falls through to the query fallback below; any other
            // transient/unknown error is translated to `creationFailed` so it
            // never escapes as a raw `CloudKitServiceError` and never silently
            // resolves against a stale or wrong profile.
            guard case .notFound = error else { throw FamilyServiceError.creationFailed }
        }

        let profiles: [Profile]
        do {
            profiles = try await cloudKit.query(
                Profile.self,
                predicate: NSPredicate(value: true),
                in: zoneID,
                using: db
            )
        } catch {
            // Translate the query path's transient/unknown errors to
            // `creationFailed` — no raw `CloudKitServiceError` escapes.
            throw FamilyServiceError.creationFailed
        }
        // Prefer the family's actual creator if present (active OR inactive) so
        // the reactivation path repairs the original identity rather than
        // minting a parallel GM for the same user.
        let existingGM = profiles.first(where: { $0.role == .guildMaster && $0.id == creatorID })
            ?? profiles.first(where: { $0.role == .guildMaster })
            ?? profiles.first(where: { $0.isActive })
        if let gm = existingGM {
            if gm.isActive {
                logger.info("Query fallback found active Guild Master profile: '\(gm.displayName, privacy: .public)'")
                return gm
            }
            logger.info("Query fallback found inactive Guild Master profile '\(gm.displayName, privacy: .public)'; reactivating")
            return try await reactivateOrSaveOwner(gm, in: zoneID, family: family, using: db)
        }
        // Branch 3 — NO GM at all: mint a fresh Guild Master in the EXISTING
        // family's zone from the onboarding profile. The family record itself is
        // reused (no duplicate Family minted), preserving one-identity-per-family
        // at the family-record level even though the GM profile is missing.
        logger.info("No existing Guild Master profile found in reused family zone; creating fresh GM")
        return try await reactivateOrSaveOwner(ownerOnboarding, in: zoneID, family: family, using: db, forceCreate: true)
    }

    /// Shared save path for `resolveExistingOwnerProfile`: either reactivates an
    /// existing inactive Guild Master (`forceCreate == false`, preserving its
    /// identity) or mints a fresh Guild Master from an onboarding profile
    /// (`forceCreate == true`, normalizing role/family/active as in the
    /// brand-new-family branch). Both shapes are persisted via a single
    /// private-database save so the result lands in CloudKit and is re-decoded
    /// with any server-stamped fields. A save failure surfaces as
    /// `FamilyServiceError.creationFailed` (no orphaned optimistic state).
    private func reactivateOrSaveOwner(_ profile: Profile,
                                       in zoneID: CKRecordZone.ID,
                                       family: Family,
                                       using db: CKDatabase?,
                                       forceCreate: Bool = false) async throws -> Profile
    {
        var owner = profile
        if forceCreate {
            owner.role = .guildMaster
            owner.family = CKRecord.Reference(recordID: family.id, action: .none)
        }
        // Ensure reactivation flips the active bit (idempotent when already
        // active — Branch 1 returns earlier and never reaches this path).
        owner.isActive = true
        do {
            let saved = try await cloudKit.save(owner, in: zoneID, using: db)
            cacheService?.upsertProfile(saved)
            return saved
        } catch {
            throw FamilyServiceError.creationFailed
        }
    }

    /// Shared session-saving tail for both the brand-new and reused owner-family
    /// paths of `createFamily`. Writes the resolved zone/ownership state to
    /// `AppState`, activates the owner path on `CloudKitService`, persists the
    /// session, and returns the owner-triple consumed by the onboarding flow.
    private func finalizeOwnerSession(family: Family,
                                      profile: Profile,
                                      zoneID: CKRecordZone.ID,
                                      shareURL: URL?) -> OwnerSessionResult
    {
        appState.familyZoneID = zoneID
        appState.isZoneOwner = true
        appState.activeShareURL = shareURL
        cloudKit.activeFamilyZoneID = zoneID
        cloudKit.activeIsOwner = true
        appState.saveSession(profile: profile, family: family, zoneID: zoneID, isOwner: true)
        return OwnerSessionResult(family: family, profile: profile, shareURL: shareURL)
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
