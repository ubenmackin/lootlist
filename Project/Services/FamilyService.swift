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

        // Step 1: Create the custom zone in the private database.
        do {
            try await cloudKit.ensureZoneExists(zoneID)
        } catch {
            throw FamilyServiceError.creationFailed
        }

        var family = Family(name: name,
                            createdBy: ownerProfile.id,
                            id: familyID)

        let pvtDB = cloudKit.privateDatabase

        // Step 2: Save the Family record in the private database.
        do {
            family = try await cloudKit.save(family, in: zoneID, using: pvtDB)
            cacheService?.upsertFamily(family)
        } catch {
            throw FamilyServiceError.creationFailed
        }

        // Step 3: Create a CKShare for the Family record.
        var shareURL: URL?
        do {
            let targetID = CKRecord.ID(recordName: familyID.recordName, zoneID: zoneID)
            shareURL = try await cloudKit.fetchOrCreateShareURL(in: zoneID, rootRecordID: targetID)
        } catch {
            logger.error("CKShare creation failed: \(error, privacy: .private)")
        }

        // Step 4: Save the Guild Master profile in the private database.
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

        // Update AppState and CloudKitService with zone ownership info.
        appState.familyZoneID = zoneID
        appState.isZoneOwner = true
        appState.activeShareURL = shareURL
        cloudKit.activeFamilyZoneID = zoneID
        cloudKit.activeIsOwner = true
        appState.saveSession(profile: savedOwner, family: family, zoneID: zoneID, isOwner: true)

        return (family, savedOwner, shareURL)
    }

    // MARK: - Join Family (Hero Flow via CKShare Link)

    func joinFamilyViaShare(metadata: CKShare.Metadata,
                            heroProfile: Profile) async throws -> (family: Family, profile: Profile)
    {
        // Step 1: Accept the CKShare.
        do {
            try await cloudKit.acceptShare(metadata: metadata)
        } catch {
            throw FamilyServiceError.joinFailed
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
            metadata.hierarchicalRootRecordID ?? CKRecord.ID(recordName: "root")
        } else {
            metadata.rootRecordID
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

        // Step 4: Save the Hero profile in the shared zone.
        var hero = heroProfile
        hero.role = .hero
        hero.family = CKRecord.Reference(recordID: family.id, action: .none)
        hero.isActive = true

        let savedHero: Profile
        do {
            savedHero = try await cloudKit.save(hero, in: zoneID, using: sharedDB)
            cacheService?.upsertProfile(savedHero)
        } catch {
            throw FamilyServiceError.joinFailed
        }

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

    // MARK: - Family Settings Updates

    @discardableResult
    func updateFamilyName(family: Family, newName: String) async throws -> Family {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw FamilyServiceError.persistenceFailed
        }
        // Privileged mutation: a parent (Guild Master / Ranger) may rename the
        // family, or the owner anchor may grant it even for a non-parent role.
        let actingIsParent = appState.currentProfile?.role.isParent ?? false
        // The owner-anchor grant applies only when the family carries a
        // server-authenticated creator stamp; a legacy family (nil creator)
        // stays strictly parent-gated.
        let ownerAnchorGrant: Bool = if family.creatorUserRecordName != nil {
            await isFamilyOwner(family)
        } else {
            false
        }
        guard actingIsParent || ownerAnchorGrant else {
            throw FamilyServiceError.unauthorized
        }

        var updated = family
        updated.name = trimmed

        let name = family.id.recordName
        let snapshot = cacheService?.fetchFamily(recordName: name)

        // Capture the last-seen server changeTag BEFORE the optimistic write so
        // we can detect a concurrent edit from another device (or background
        let preMutationChangeTag = snapshot?.changeTag

        // Capture an immutable value-type copy of the snapshot BEFORE the
        // optimistic write. The cache-managed `snapshot` will be mutated in
        // place by `upsertFamily`, so reading `snapshot.toFamily(...)` later
        // would yield the *post*-mutation values. The value-type copy
        // (`Family` struct) is unaffected by later mutations.
        // changeTag rehydrated from cache row per toX(zoneID:), safe for use in ConcurrentEditDetector.
        let snapshotFamily: Family? = snapshot?.toFamily(zoneID: cloudKit.resolvedZoneID)

        // Register the optimistic window so a background sync skips this row.
        let registry = cacheService?.inFlightRegistry
        await registry?.register(name)

        cacheService?.upsertFamily(updated)
        appState.family = updated

        let (zoneID, db) = familyContext(for: family.id)
        do {
            let saved = try await cloudKit.save(updated, in: zoneID, using: db)
            cacheService?.upsertFamily(saved)
            appState.family = saved
            await registry?.deregister(name)
            return saved
        } catch {
            await OptimisticFailureHandler.handleSaveFailure(
                recordID: family.id,
                preMutationChangeTag: preMutationChangeTag,
                snapshot: snapshotFamily,
                cloudKit: cloudKit,
                toastManager: toastManager,
                fetchCurrentTag: { self.cacheService?.fetchFamily(recordName: name)?.changeTag },
                upsert: { restored in
                    self.cacheService?.upsertFamily(restored)
                    self.appState.family = restored
                },
                invalidate: { _ in self.cacheService?.invalidateFamily(recordName: name) },
                error: error,
                db: db
            )
            await registry?.deregister(name)
            throw FamilyServiceError.persistenceFailed
        }
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
            if let userRecordID = try? await cloudKit.currentUserRecordID() {
                return userRecordID.recordName == anchor
            }
            return false
        }
        return appState.isZoneOwner
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
