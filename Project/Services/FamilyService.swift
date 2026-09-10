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

/// Outcome of member removal, tracking profile deactivation and share revocation.
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
    func refreshProfilesFromCloudKit(for family: Family) async
    func requestProfileSync(for family: Family) async
    func currentUserRecordName() async throws -> String
    func prepareInviteShare(for family: Family, role: UserRole) async throws -> CKShare
    func prepareInvitePresentation(for family: Family, role: UserRole) async throws -> CloudSharePresentation
    func fetchShareParticipants(for family: Family) async throws -> [CKShare.Participant]
    func fetchShareParticipantStatuses(for family: Family) async throws -> [ShareParticipantStatus]
    func fetchShareParticipantRoles(for family: Family) async throws -> [String: UserRole]
    func revokeInvitation(participant: CKShare.Participant, from family: Family) async throws
    func revokeInvitation(identityRecordName: String, from family: Family) async throws
    func revokeInvitation(identityKey: String, from family: Family) async throws
}

extension FamilyProfileFetching {
    /// WHY default identity-key revocation lives here: test doubles conforming to
    /// this protocol inherit working behavior without spelling CloudKit types in
    /// ViewModels, so this is the single revocation path.
    func revokeInvitation(identityKey: String, from family: Family) async throws {
        guard !identityKey.isEmpty else {
            throw CloudKitServiceError.shareFailed("No participant identity to revoke — refresh invitations and try again")
        }
        let participants = try await fetchShareParticipants(for: family)
        guard let match = participants.first(where: { ShareParticipantKey.key(for: $0) == identityKey }) else {
            throw CloudKitServiceError.shareFailed("No role share contains a participant matching this identity — the revocation was not performed")
        }
        try await revokeInvitation(participant: match, from: family)
    }

    func prepareInvitePresentation(for family: Family, role: UserRole) async throws -> CloudSharePresentation {
        let share = try await prepareInviteShare(for: family, role: role)
        if let service = self as? FamilyService {
            return service.invitePresentation(for: share)
        }
        let container = CKContainer.default()
        let shareURL = share.url
        return CloudSharePresentation(shareURL: shareURL) {
            let allowedOptions = CKAllowedSharingOptions(
                allowedParticipantPermissionOptions: [.readWrite],
                allowedParticipantAccessOptions: [.specifiedRecipientsOnly]
            )
            let provider = NSItemProvider()
            provider.registerCKShare(share, container: container, allowedSharingOptions: allowedOptions)
            return provider
        }
    }

    /// WHY lifecycle seam: test doubles inherit a no-op sync so ViewModels stay cache-driven without CloudKit.
    func requestProfileSync(for _: Family) async {}
}

/// The owner-family session result consumed by the onboarding flow: the
/// resolved `Family` and the Guild Master `Profile`. Backs both the brand-new
/// and reused-family paths of `createFamily`.
struct OwnerSessionResult {
    let family: Family
    let profile: Profile
}

/// Join session result returning resolved Family, Profile, and active reuse status.
struct JoinedFamilyResult {
    let family: Family
    let profile: Profile
    let didReuseActiveProfile: Bool
}

// MARK: - FamilyService

@MainActor
@Observable
final class FamilyService: FamilyProfileFetching {
    let logger = Logger(category: "Security")

    let cloudKit: any CloudKitServiceProtocol
    let appState: AppState
    let questService: QuestService

    var cacheService: CacheService? {
        didSet {
            if let cacheService {
                questService.cacheService = cacheService
            }
        }
    }

    var syncCoordinator: CKSyncEngineCoordinator?

    let toastManager: ToastManager?

    /// Bootstrap seeder for default achievements during family creation.
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

    /// Deduplicates concurrent profile refresh operations in flight for the same family.
    private let refreshInFlightKeys = Mutex<Set<String>>([])

    // MARK: - Identity Caching

    /// Resolves and caches current iCloud user record ID per session.
    private var cachedUserRecordIDTask: Task<CKRecord.ID, any Error>?

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

        // Deduplicate parent family before zone creation to prevent orphan zones on re-onboarding.
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
            await cacheService?.upsertFamily(existingFamily)
            await cacheService?.upsertProfile(resolvedOwner)

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

        // WHY server stamps creator: decoded only on read path, never authored locally.
        var family = Family(name: name,
                            creatorUserRecordName: nil,
                            id: familyID)

        let pvtDB = cloudKit.privateDatabase

        do {
            family = try await cloudKit.save(family, in: zoneID, using: pvtDB)
            // Direct pre-session mirror: ingestion drops rows until the owner session exists.
            await cacheService?.upsertFamily(family, isServerSync: true)
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
            // Direct pre-session mirror: ingestion drops rows until the owner session exists.
            await cacheService?.upsertProfile(savedOwner, isServerSync: true)
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

    /// Seeds default achievements idempotently using deterministic record names.
    private func seedDefaultAchievements(for family: Family) async {
        if let cacheService {
            let familyName = family.id.recordName
            let cached = cacheService.fetchAchievements(family: familyName)
            if cached.isEmpty {
                let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
                let defaults = AchievementService.defaultAchievements(for: familyRef)
                for ach in defaults {
                    await cacheService.upsertAchievement(ach)
                }
            }
        }
        if let achievementService {
            do {
                try await achievementService.seedDefaultAchievements(family: family)
            } catch {
                logger.warning("Failed to seed default achievements for family \(family.id.recordName, privacy: .private): \(String(describing: error), privacy: .private)")
            }
            return
        }
        // Ephemeral seeder when not injected (tests / legacy init).
        let seeder = AchievementService(
            cloudKit: cloudKit,
            cacheService: cacheService,
            appState: appState,
            syncCoordinator: syncCoordinator
        )
        do {
            try await seeder.seedDefaultAchievements(family: family)
        } catch {
            logger
                .warning(
                    "Failed to seed default achievements via ephemeral seeder for family \(family.id.recordName, privacy: .private): \(String(describing: error), privacy: .private)"
                )
        }
    }

    // MARK: - Join Family (Joiner Flow via CKShare Link)

    /// Joins family via accepted share metadata, resolving role from share title.
    func joinFamilyViaAcceptedShare(metadata: CKShare.Metadata?,
                                    displayName: String?,
                                    avatarClass: AvatarClass?,
                                    progressHandler: ((String, Double) -> Void)? = nil) async throws -> JoinedFamilyResult
    {
        logger.info("Joining family via accepted share started. hasMetadata=\(metadata != nil)")
        try await acceptShareIfNeeded(metadata: metadata, progressHandler: progressHandler)
        let sharedZones = try await fetchSharedZonesForJoin(progressHandler: progressHandler)

        let sharedDB = cloudKit.sharedDatabase

        // Point-lookup Family by ID matching the accepted share metadata.
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
            // Direct pre-session snapshot: ingestion drops rows until saveSession runs below.
            await cacheService?.upsertFamily(family, isServerSync: true)
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
        // Direct pre-session mirror: ingestion drops rows until saveSession runs below.
        await cacheService?.upsertProfile(savedProfile, isServerSync: true)

        appState.familyZoneID = zoneID
        appState.isZoneOwner = false
        cloudKit.activeFamilyZoneID = zoneID
        cloudKit.activeIsOwner = false
        appState.saveSession(profile: savedProfile, family: family, zoneID: zoneID, isOwner: false)

        // WHY lifecycle sync: post-join roster rides fetchChanges so engine ingest stays the single write path.
        await requestProfileSync(for: family)

        // Re-ingest the just-saved profile so the roster hydration above cannot
        // overwrite fresh joiner metadata with a stale snapshot.
        await syncCoordinator?.delegateHandler.hydrateFromQuery(
            models: [savedProfile],
            databaseScope: .shared,
            zoneID: zoneID
        )

        // Hero bootstrap: seed per-hero defaults so the new member has a
        // complete local state before the first sync round trips.
        await seedNotificationPreferences(for: savedProfile, family: family)
        if savedProfile.role == .hero {
            await seedAllowancePeriod(for: savedProfile, family: family)
        }
        await seedDefaultAchievements(for: family)

        progressHandler?("Joined Guild!", 1.0)
        return JoinedFamilyResult(
            family: family,
            profile: savedProfile,
            didReuseActiveProfile: didReuseActiveProfile
        )
    }

    // MARK: - Role & Membership Management

    /// Lifecycle-driven profile read backing `fetchHeroes` and `fetchAllProfilesForFamily`.
    private func fetchProfiles(for family: Family) async throws -> [Profile] {
        // WHY cache-only: roster is UI truth from lifecycle sync + cache; stale serves until re-hydrated, no CloudKit fallback.
        let familyRecordName = family.id.recordName
        guard !familyRecordName.isEmpty else { return [] }
        guard let cache = cacheService else { return [] }
        return cache.fetchProfiles(family: familyRecordName).map { $0.toProfile(zoneID: family.id.zoneID) }
    }

    /// Lifecycle seam for ViewModel roster refresh; rides the sync engine so ingest stays the single write path.
    func requestProfileSync(for family: Family) async {
        // WHY fail-closed: empty scope or unresolved database never triggers a sync pass.
        guard !family.id.recordName.isEmpty else { return }
        guard DatabaseScopeResolver.resolvedScope(appState: appState) != nil else { return }
        await syncCoordinator?.fetchChanges()
    }

    /// Cache-only read riding lifecycle sync + cache.
    func fetchHeroes(for family: Family) async throws -> [Profile] {
        try await fetchProfiles(for: family)
            .filter { $0.role == .hero && $0.isActive }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Cache-only read riding lifecycle sync + cache.
    func fetchAllProfilesForFamily(_ family: Family) async throws -> [Profile] {
        let profileSort: (Profile, Profile) -> Bool = { lhs, rhs in
            if lhs.isActive != rhs.isActive {
                return lhs.isActive && !rhs.isActive
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        return try await fetchProfiles(for: family).sorted(by: profileSort)
    }

    func requireLiveOwnerFamily(familyID: CKRecord.ID) async throws -> Family {
        // WHY server-authoritative anchor: stale cache must not grant irreversible writes, so prefer the live creator when reachable.
        let (_, db) = familyContext(for: familyID)
        do {
            let server = try await cloudKit.fetch(Family.self, id: familyID, using: db)
            // WHY owner-only: unresolved anchor denies; legacy dev rows need zone wipe/re-create, no backfill.
            guard await isFamilyOwner(server) else {
                throw FamilyServiceError.unauthorized
            }
            return server
        } catch let error as FamilyServiceError {
            throw error
        } catch {
            // WHY cache fallback: live fetch unreachable offline, so resolve from last synced snapshot.
            guard let cached = cacheService?.fetchFamily(recordName: familyID.recordName)?.toFamily(zoneID: familyID.zoneID),
                  await isFamilyOwner(cached)
            else {
                throw FamilyServiceError.unauthorized
            }
            return cached
        }
    }

    func requireFamilyOwner(for profile: Profile) async throws -> Family {
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            familyRecordName: profile.family.recordID.recordName,
            zoneID: profile.family.recordID.zoneID,
            appState: appState,
            cloudKit: cloudKit
        )
        return try await requireLiveOwnerFamily(familyID: profile.family.recordID)
    }

    func updateMemberRole(profile: Profile, newRole: UserRole) async throws {
        // Role mutation reserved for server-authenticated family owner anchor.
        _ = try await requireFamilyOwner(for: profile)

        var updated = profile
        updated.role = newRole

        await cacheService?.upsertProfile(updated)
        if appState.currentProfile?.id == updated.id {
            appState.currentProfile = updated
        }
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: updated.id, appState: appState, logger: logger, context: "FamilyService.updateMemberRole")
    }

    // MARK: - Private Helpers

    /// Server-authenticated owner check, anchored on CloudKit's read-only
    /// `creatorUserRecordID`. Denies when the creator is unresolved.
    func isFamilyOwner(_ family: Family) async -> Bool {
        // WHY deny-by-default: nil/empty/placeholder/self-referencing anchors deny; legacy dev rows need zone wipe/re-create, no backfill.
        guard let anchor = family.creatorUserRecordName, !anchor.isEmpty,
              !ActiveFamilyScopeGuard.isPlaceholderOwner(anchor),
              anchor != family.id.recordName
        else {
            return false
        }
        // Re-resolve current user freshly to avoid stale cached identity across account changes.
        do {
            let userRecordID = try await cloudKit.currentUserRecordID()
            return ActiveFamilyScopeGuard.isUserRecordNameMatch(userRecordID.recordName, anchor)
        } catch {
            logger.warning("Could not resolve current user for owner check: \(error, privacy: .private)")
            return false
        }
    }

    /// Resolves current user's iCloud user record ID once per session.
    private func resolveCurrentUserRecordID() async throws -> CKRecord.ID {
        if let existingTask = cachedUserRecordIDTask {
            do {
                return try await existingTask.value
            } catch {
                cachedUserRecordIDTask = nil
                throw FamilyServiceError.accountUnavailable
            }
        }
        let newTask = Task<CKRecord.ID, any Error> {
            try await cloudKit.currentUserRecordID()
        }
        // Coalesce: if another caller stored a task between our check and creation,
        // await the existing one instead. On MainActor this window is empty (no
        // await between check and store), but keep the guard for explicitness.
        if let existingTask = cachedUserRecordIDTask {
            newTask.cancel()
            do {
                return try await existingTask.value
            } catch {
                cachedUserRecordIDTask = nil
                throw FamilyServiceError.accountUnavailable
            }
        }
        cachedUserRecordIDTask = newTask
        do {
            return try await newTask.value
        } catch {
            cachedUserRecordIDTask = nil
            throw FamilyServiceError.accountUnavailable
        }
    }

    /// Resets the memoized iCloud user record ID task on account change or sign-out.
    func resetCachedUserRecordID() {
        cachedUserRecordIDTask?.cancel()
        cachedUserRecordIDTask = nil
    }

    /// Resolves Family for a member profile via cache-first lookup.
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

    private func acceptShareIfNeeded(metadata: CKShare.Metadata?, progressHandler: ((String, Double) -> Void)?) async throws {
        guard let metadata else { return }
        progressHandler?("Accepting family invitation...", 0.4)
        logger.info("Invoking cloudKit.acceptShare(metadata)...")
        do {
            try await cloudKit.acceptShare(metadata: metadata)
            logger.info("Accept family share succeeded.")
        } catch {
            logger.error("Accept family share failed: \(error, privacy: .private)")
            // Preserve underlying CKError for invalid-invitation surfacing.
            throw error
        }
    }

    private func fetchSharedZonesForJoin(progressHandler: ((String, Double) -> Void)?) async throws -> [CKRecordZone] {
        progressHandler?("Connecting to family Guild...", 0.65)
        logger.info("Fetching shared zones from cloudKit...")
        do {
            let zones = try await cloudKit.fetchSharedZones()
            logger.info("Found \(zones.count) shared zones.")
            return zones
        } catch {
            logger.error("Fetching shared zones failed: \(error, privacy: .private)")
            throw FamilyServiceError.joinFailed
        }
    }

    /// Lifecycle-driven roster refresh; rides the sync engine so ingest stays the single write path.
    func refreshProfilesFromCloudKit(for family: Family) async {
        let key = "profiles|\(family.id.recordName)"
        let alreadyInFlight = refreshInFlightKeys.withLock {
            if $0.contains(key) {
                return true
            }; $0.insert(key); return false
        }
        guard !alreadyInFlight else { return }
        defer { refreshInFlightKeys.withLock { _ = $0.remove(key) } }

        // WHY lifecycle sync: roster refresh rides fetchChanges so engine ingest stays the single write path.
        await requestProfileSync(for: family)
        // WHY test hydration: engines never run under tests, so mock query fills cache without live zone fetch.
        guard TestEnvironment.isRunningUnitOrUITests else { return }
        guard !family.id.recordName.isEmpty else { return }
        guard let resolvedScope = DatabaseScopeResolver.resolvedScope(appState: appState) else { return }
        do {
            let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
            let predicate = NSPredicate(format: "family == %@", familyRef)
            let (_, db) = familyContext(for: family.id)
            let profiles: [Profile] = try await cloudKit.query(Profile.self, predicate: predicate, in: family.id.zoneID, using: db)
            let records = profiles.map { $0.toRecord() }
            guard !records.isEmpty else { return }
            if let coordinator = syncCoordinator {
                let outcome = await coordinator.delegateHandler.handleIncomingRecordsDirectly(
                    records,
                    databaseScope: resolvedScope,
                    zoneID: family.id.zoneID
                )
                // WHY engine path already landed: skip ephemeral replay when ingest committed.
                if outcome?.didCommit == true {
                    return
                }
            }
            // WHY engine-less tests: ephemeral handler rides the same ingest checks and batching.
            await hydrateProfilesWithoutEngine(records, databaseScope: resolvedScope, zoneID: family.id.zoneID)
        } catch {
            logger.warning("Profile refresh query skipped: \(error, privacy: .private)")
        }
    }

    /// Test-only hydration riding the same ingest pipeline when no engine backs the coordinator.
    private func hydrateProfilesWithoutEngine(_ records: [CKRecord], databaseScope: CKDatabase.Scope, zoneID: CKRecordZone.ID) async {
        guard let cacheService else { return }
        // WHY reuse shared writer: lifecycle-owned actor keeps one batching context when present.
        if let existing = appState.backgroundCacheActor {
            let resolver = CKSyncConflictResolver(cacheService: cacheService, appState: appState)
            let handler = CKSyncEngineDelegateHandler(
                backgroundCache: existing,
                conflictResolver: resolver,
                cacheService: cacheService,
                appState: appState
            )
            await handler.handleIncomingRecordsDirectly(records, databaseScope: databaseScope, zoneID: zoneID)
            return
        }
        guard let container = cacheService.container else { return }
        // WHY ephemeral batching: in-memory stores never bootstrap a writer, so one is minted for this pass.
        let writer = BackgroundCacheActor(container: container)
        let resolver = CKSyncConflictResolver(cacheService: cacheService, backgroundCache: writer, appState: appState)
        let handler = CKSyncEngineDelegateHandler(
            backgroundCache: writer,
            conflictResolver: resolver,
            cacheService: cacheService,
            appState: appState
        )
        await handler.handleIncomingRecordsDirectly(records, databaseScope: databaseScope, zoneID: zoneID)
    }

    // MARK: - Hero Bootstrap Seeding

    /// Seeds default notification preferences for newly joined heroes.
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
        await cacheService.upsertNotificationPreferences(missing, family: familyRecordName)
        ActiveFamilyScopeGuard.batchEnqueueWithCorrectedOwner(
            syncCoordinator,
            ids: missing.map(\.id),
            appState: appState,
            logger: logger,
            context: "FamilyService.seedNotificationPreferences"
        )
    }

    /// Seeds current-week allowance period for newly joined heroes.
    private func seedAllowancePeriod(for profile: Profile, family: Family) async {
        guard profile.role == .hero else { return }
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
            // Handles allowance period initialization with retry error handling.
            do {
                _ = try await treasuryService.getOrCreateAllowancePeriod(profile: profile, weekOf: startOfWeek, family: family)
            } catch {
                logger
                    .warning(
                        "Failed to seed allowance period for hero \(profile.id.recordName, privacy: .private) in family \(family.id.recordName, privacy: .private): \(error, privacy: .private)"
                    )
                toastManager?.show(message: "Could not create allowance period. Pull to retry.", type: .warning)
            }
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
        await cacheService.upsertAllowancePeriod(period)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: period.id, appState: appState, logger: logger, context: "FamilyService.seedAllowancePeriod")
    }

    /// Sanctioned join-dedupe door: finds joining user's existing Profile before creating a new one.
    func findExistingProfileForCurrentUser(in zoneID: CKRecordZone.ID,
                                           family: Family,
                                           currentUserRecordID: CKRecord.ID) async throws -> Profile?
    {
        // WHY fail-closed: empty scope or zone mismatch denies dedupe rather than risking a duplicate.
        guard !family.id.recordName.isEmpty, !currentUserRecordID.recordName.isEmpty else {
            throw FamilyServiceError.joinFailed
        }
        guard zoneID == family.id.zoneID else {
            throw FamilyServiceError.joinFailed
        }
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
        let isOwner = (recordID.zoneID.ownerName == CKCurrentUserDefaultName) ||
            (appState.family?.id.recordName == recordID.recordName && ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState))
        let db = cloudKit.database(isOwner: isOwner)
        return (zoneID, db)
    }
}
