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

enum FamilyServiceError: Error, Equatable, Sendable {
    case invalidInviteCode
    case joinFailed(String)
    case creationFailed(String)
    case persistenceFailed(String)
    case accountUnavailable
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

    private let cloudKit: CloudKitService
    private let appState: AppState
    private let questService: QuestService
    var cacheService: CacheService?

    var cloudKitReference: CloudKitService {
        cloudKit
    }

    var toastManager: ToastManager?

    /// Keys of immediate profile refreshes currently in flight, formatted as
    /// `"<operation>|<familyRecordName>"`. Actor-isolated dedupe guard: when a
    /// genuinely-required immediate refresh for the same operation + family is
    /// already running, concurrent callers collapse onto it instead of issuing
    /// duplicate CloudKit queries that race SyncEngine's push-driven incremental
    /// sync and duplicate server-derived writes.
    private let refreshInFlightKeys = Mutex<Set<String>>([])

    init(cloudKit: CloudKitService, appState: AppState, questService: QuestService, cacheService: CacheService? = nil) {
        self.cloudKit = cloudKit
        self.appState = appState
        self.questService = questService
        self.cacheService = cacheService
    }

    // MARK: - Family Creation (Guild Master Flow)

    @discardableResult
    func createFamily(name: String,
                      ownerProfile: Profile) async throws -> (family: Family, profile: Profile, shareURL: URL?) // swiftlint:disable:this large_tuple
    {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw FamilyServiceError.creationFailed("Family name cannot be empty.")
        }

        let familyID = CKRecord.ID(recordName: UUID().uuidString)
        let zoneID = CKRecordZone.ID(zoneName: familyID.recordName,
                                     ownerName: CKCurrentUserDefaultName)

        // Step 1: Create the custom zone in the private database.
        do {
            try await cloudKit.ensureZoneExists(zoneID)
        } catch {
            throw FamilyServiceError.creationFailed(
                "Could not create family zone: \(error)"
            )
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
            throw FamilyServiceError.creationFailed(
                "Could not save family record: \(error)"
            )
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
            throw FamilyServiceError.creationFailed(
                "Could not save guild master profile: \(error)"
            )
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
            throw FamilyServiceError.joinFailed(
                "Could not accept share invitation: \(error)"
            )
        }

        // Step 2: Discover the shared zone.
        let sharedZones: [CKRecordZone]
        do {
            sharedZones = try await cloudKit.fetchSharedZones()
        } catch {
            throw FamilyServiceError.joinFailed(
                "Could not discover shared zones: \(error)"
            )
        }

        guard let familyZone = sharedZones.first else {
            throw FamilyServiceError.joinFailed(
                "No shared family zone found after accepting invitation."
            )
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
            throw FamilyServiceError.joinFailed(
                "Could not fetch family record in shared zone: \(error)"
            )
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
            throw FamilyServiceError.joinFailed(
                "Could not save hero profile: \(error)"
            )
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
        // belong to SyncEngine (D5).
        await refreshProfilesFromCloudKit(for: family)

        return (family, savedHero)
    }

    // MARK: - Family Settings Updates

    @discardableResult
    func updateFamilyName(family: Family, newName: String) async throws -> Family {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw FamilyServiceError.persistenceFailed("Family name cannot be empty.")
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
            let concurrentEditDetected = ConcurrentEditDetector.detectConcurrentEdit(
                preMutationChangeTag: preMutationChangeTag,
                fetchCurrent: { cacheService?.fetchFamily(recordName: name)?.changeTag },
                error: error
            )

            if concurrentEditDetected {
                // Concurrent edit: the server has a newer record. Discard our optimistic
                // write by re-fetching the authoritative server record, OR fall back to
                // the pre-mutation snapshot if the re-fetch also fails.
                toastManager?.show(
                    message: "Data was modified by another device. Refresh to see the latest.",
                    type: .warning
                )

                if let fresh = try? await cloudKit.fetch(Family.self, id: family.id, using: db) {
                    cacheService?.upsertFamily(fresh)
                    appState.family = fresh
                } else if let snapshotFamily {
                    cacheService?.upsertFamily(snapshotFamily)
                    appState.family = snapshotFamily
                }
            } else {
                if let snapshotFamily {
                    cacheService?.upsertFamily(snapshotFamily)
                    appState.family = snapshotFamily
                }
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                toastManager?.show(message: message, type: .error)
            }
            await registry?.deregister(name)
            throw FamilyServiceError.persistenceFailed(
                "Could not update family name: \(error)"
            )
        }
    }

    @discardableResult
    func updatePayoutPolicy(family: Family, policy: PayoutPolicy) async throws -> Family {
        var updated = family
        updated.payoutPolicy = policy

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
            let concurrentEditDetected = ConcurrentEditDetector.detectConcurrentEdit(
                preMutationChangeTag: preMutationChangeTag,
                fetchCurrent: { cacheService?.fetchFamily(recordName: name)?.changeTag },
                error: error
            )

            if concurrentEditDetected {
                // Concurrent edit: the server has a newer record. Discard our optimistic
                // write by re-fetching the authoritative server record, OR fall back to
                // the pre-mutation snapshot if the re-fetch also fails.
                toastManager?.show(
                    message: "Data was modified by another device. Refresh to see the latest.",
                    type: .warning
                )

                if let fresh = try? await cloudKit.fetch(Family.self, id: family.id, using: db) {
                    cacheService?.upsertFamily(fresh)
                    appState.family = fresh
                } else if let snapshotFamily {
                    cacheService?.upsertFamily(snapshotFamily)
                    appState.family = snapshotFamily
                }
            } else {
                if let snapshotFamily {
                    cacheService?.upsertFamily(snapshotFamily)
                    appState.family = snapshotFamily
                }
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                toastManager?.show(message: message, type: .error)
            }
            await registry?.deregister(name)
            throw FamilyServiceError.persistenceFailed(
                "Could not update payout policy: \(error)"
            )
        }
    }

    @discardableResult
    func updateProfilePayoutPolicy(profile: Profile, policy: PayoutPolicy) async throws -> Profile {
        var updated = profile
        updated.payoutPolicy = policy

        let name = profile.id.recordName
        let snapshot = cacheService?.fetchProfile(recordName: name)

        // Capture the last-seen server changeTag BEFORE the optimistic write so
        // we can detect a concurrent edit from another device (or background
        let preMutationChangeTag = snapshot?.changeTag

        // Capture an immutable value-type copy of the snapshot BEFORE the
        // optimistic write. The cache-managed `snapshot` will be mutated in
        // place by `upsertProfile`, so reading `snapshot.toProfile(...)` later
        // would yield the *post*-mutation values. The value-type copy
        // (`Profile` struct) is unaffected by later mutations.
        // changeTag rehydrated from cache row per toX(zoneID:), safe for use in ConcurrentEditDetector.
        let snapshotProfile: Profile? = snapshot?.toProfile(zoneID: cloudKit.resolvedZoneID)

        // Register the optimistic window so a background sync skips this row.
        let registry = cacheService?.inFlightRegistry
        await registry?.register(name)

        cacheService?.upsertProfile(updated)
        if appState.currentProfile?.id == profile.id {
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
            return saved
        } catch {
            let concurrentEditDetected = ConcurrentEditDetector.detectConcurrentEdit(
                preMutationChangeTag: preMutationChangeTag,
                fetchCurrent: { cacheService?.fetchProfile(recordName: name)?.changeTag },
                error: error
            )

            if concurrentEditDetected {
                // Concurrent edit: the server has a newer record. Discard our optimistic
                // write by re-fetching the authoritative server record, OR fall back to
                // the pre-mutation snapshot if the re-fetch also fails.
                toastManager?.show(
                    message: "Data was modified by another device. Refresh to see the latest.",
                    type: .warning
                )

                if let fresh = try? await cloudKit.fetch(Profile.self, id: profile.id, using: db) {
                    cacheService?.upsertProfile(fresh)
                    if appState.currentProfile?.id == profile.id {
                        appState.currentProfile = fresh
                    }
                } else if let snapshotProfile {
                    cacheService?.upsertProfile(snapshotProfile)
                    if appState.currentProfile?.id == profile.id {
                        appState.currentProfile = snapshotProfile
                    }
                }
            } else {
                if let snapshotProfile {
                    cacheService?.upsertProfile(snapshotProfile)
                    if appState.currentProfile?.id == profile.id {
                        appState.currentProfile = snapshotProfile
                    }
                }
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                toastManager?.show(message: message, type: .error)
            }
            await registry?.deregister(name)
            throw FamilyServiceError.persistenceFailed(
                "Could not update profile payout policy: \(error)"
            )
        }
    }

    @discardableResult
    func updateProfileDisplayName(profile: Profile, newName: String) async throws -> Profile {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FamilyServiceError.persistenceFailed("Character name cannot be empty.")
        }

        var updated = profile
        updated.displayName = trimmed

        let name = profile.id.recordName
        let snapshot = cacheService?.fetchProfile(recordName: name)

        // Capture the last-seen server changeTag BEFORE the optimistic write so
        // we can detect a concurrent edit from another device (or background
        let preMutationChangeTag = snapshot?.changeTag

        // Capture an immutable value-type copy of the snapshot BEFORE the
        // optimistic write. The cache-managed `snapshot` will be mutated in
        // place by `upsertProfile`, so reading `snapshot.toProfile(...)` later
        // would yield the *post*-mutation values. The value-type copy
        // (`Profile` struct) is unaffected by later mutations.
        // changeTag rehydrated from cache row per toX(zoneID:), safe for use in ConcurrentEditDetector.
        let snapshotProfile: Profile? = snapshot?.toProfile(zoneID: cloudKit.resolvedZoneID)

        // Register the optimistic window so a background sync skips this row.
        let registry = cacheService?.inFlightRegistry
        await registry?.register(name)

        cacheService?.upsertProfile(updated)
        if appState.currentProfile?.id == profile.id {
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
            return saved
        } catch {
            let concurrentEditDetected = ConcurrentEditDetector.detectConcurrentEdit(
                preMutationChangeTag: preMutationChangeTag,
                fetchCurrent: { cacheService?.fetchProfile(recordName: name)?.changeTag },
                error: error
            )

            if concurrentEditDetected {
                // Concurrent edit: the server has a newer record. Discard our optimistic
                // write by re-fetching the authoritative server record, OR fall back to
                // the pre-mutation snapshot if the re-fetch also fails.
                toastManager?.show(
                    message: "Data was modified by another device. Refresh to see the latest.",
                    type: .warning
                )

                if let fresh = try? await cloudKit.fetch(Profile.self, id: profile.id, using: db) {
                    cacheService?.upsertProfile(fresh)
                    if appState.currentProfile?.id == profile.id {
                        appState.currentProfile = fresh
                    }
                } else if let snapshotProfile {
                    cacheService?.upsertProfile(snapshotProfile)
                    if appState.currentProfile?.id == profile.id {
                        appState.currentProfile = snapshotProfile
                    }
                }
            } else {
                if let snapshotProfile {
                    cacheService?.upsertProfile(snapshotProfile)
                    if appState.currentProfile?.id == profile.id {
                        appState.currentProfile = snapshotProfile
                    }
                }
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                toastManager?.show(message: message, type: .error)
            }
            await registry?.deregister(name)
            throw FamilyServiceError.persistenceFailed(
                "Could not update character name: \(error)"
            )
        }
    }

    @discardableResult
    func updateProfileAvatar(profile: Profile,
                             avatarClass: AvatarClass?,
                             avatarPresetID: String?,
                             customAvatarImageData: Data?) async throws -> Profile
    {
        var updated = profile
        updated.avatarClass = avatarClass
        updated.avatarPresetID = avatarPresetID
        updated.customAvatarImageData = customAvatarImageData

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
            return saved
        } catch {
            if ConcurrentEditDetector.detectConcurrentEdit(
                preMutationChangeTag: preMutationChangeTag,
                fetchCurrent: { self.cacheService?.fetchProfiles(family: profile.family.recordID.recordName)
                    .first(where: { $0.recordName == name })?.changeTag
                },
                error: error
            ) {
                toastManager?.show(
                    message: "Data was modified by another device. Refresh to see the latest.",
                    type: .warning
                )
                if let fresh = try? await cloudKit.fetch(Profile.self, id: profile.id, using: db) {
                    cacheService?.upsertProfile(fresh)
                    if appState.currentProfile?.id == fresh.id {
                        appState.currentProfile = fresh
                    }
                } else if let snapshotProfile {
                    cacheService?.upsertProfile(snapshotProfile)
                    if appState.currentProfile?.id == snapshotProfile.id {
                        appState.currentProfile = snapshotProfile
                    }
                }
            } else {
                if let snapshotProfile {
                    cacheService?.upsertProfile(snapshotProfile)
                    if appState.currentProfile?.id == snapshotProfile.id {
                        appState.currentProfile = snapshotProfile
                    }
                }
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                toastManager?.show(message: message, type: .error)
            }
            await registry?.deregister(name)
            throw FamilyServiceError.persistenceFailed(
                "Could not update avatar: \(error)"
            )
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
            if ConcurrentEditDetector.detectConcurrentEdit(
                preMutationChangeTag: preMutationChangeTag,
                fetchCurrent: { self.cacheService?.fetchProfiles(family: profile.family.recordID.recordName)
                    .first(where: { $0.recordName == name })?.changeTag
                },
                error: error
            ) {
                toastManager?.show(
                    message: "Data was modified by another device. Refresh to see the latest.",
                    type: .warning
                )
                if let fresh = try? await cloudKit.fetch(Profile.self, id: profile.id, using: db) {
                    cacheService?.upsertProfile(fresh)
                    if appState.currentProfile?.id == fresh.id {
                        appState.currentProfile = fresh
                    }
                } else if let snapshotProfile {
                    cacheService?.upsertProfile(snapshotProfile)
                    if appState.currentProfile?.id == snapshotProfile.id {
                        appState.currentProfile = snapshotProfile
                    }
                }
            } else {
                if let snapshotProfile {
                    cacheService?.upsertProfile(snapshotProfile)
                    if appState.currentProfile?.id == snapshotProfile.id {
                        appState.currentProfile = snapshotProfile
                    }
                }
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                toastManager?.show(message: message, type: .error)
            }
            await registry?.deregister(name)
            throw FamilyServiceError.persistenceFailed(
                "Could not update role: \(error)"
            )
        }
    }

    func leaveFamily(profile: Profile) async throws {
        await unassignActiveQuests(for: profile)
        try await deactivateProfile(profile, errorMessage: "Could not leave family")
    }

    func kickMember(profile: Profile) async throws {
        await unassignActiveQuests(for: profile)
        try await deactivateProfile(profile, errorMessage: "Could not remove member")
    }

    // MARK: - Private Helpers

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
        guard appState.family != nil else { return }
        let currentWeek = TreasuryService.mondayOfWeek(for: Date())

        #if DEBUG
            let questMonday = QuestService.mondayOfWeek(for: Date())
            assert(
                questMonday == currentWeek,
                "TreasuryService.mondayOfWeek and QuestService.mondayOfWeek diverged: \(currentWeek) vs \(questMonday)"
            )
        #endif

        let currentQuests = await (try? questService.fetchActiveQuests(profile: profile, weekOf: currentWeek)) ?? []
        let nextWeek = Calendar.iso8601UTC.date(byAdding: .weekOfYear, value: 1, to: currentWeek) ?? currentWeek
        let nextQuests = await (try? questService.fetchActiveQuests(profile: profile, weekOf: nextWeek)) ?? []

        for quest in currentQuests + nextQuests {
            try? await questService.unassignQuest(quest)
        }
    }

    private func familyContext(for _: CKRecord.ID) -> (zone: CKRecordZone.ID, db: CKDatabase) {
        let zoneID = cloudKit.resolvedZoneID // already set with correct ownerName
        let db = cloudKit.database(isOwner: appState.isZoneOwner)
        return (zoneID, db)
    }

    private func deactivateProfile(_ profile: Profile, errorMessage: String) async throws {
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
            if ConcurrentEditDetector.detectConcurrentEdit(
                preMutationChangeTag: preMutationChangeTag,
                fetchCurrent: { self.cacheService?.fetchProfiles(family: profile.family.recordID.recordName)
                    .first(where: { $0.recordName == name })?.changeTag
                },
                error: error
            ) {
                toastManager?.show(
                    message: "Data was modified by another device. Refresh to see the latest.",
                    type: .warning
                )
                if let fresh = try? await cloudKit.fetch(Profile.self, id: profile.id, using: db) {
                    cacheService?.upsertProfile(fresh)
                    if appState.currentProfile?.id == fresh.id {
                        appState.currentProfile = fresh
                    }
                } else if let snapshotProfile {
                    cacheService?.upsertProfile(snapshotProfile)
                    if appState.currentProfile?.id == snapshotProfile.id {
                        appState.currentProfile = snapshotProfile
                    }
                }
            } else {
                if let snapshotProfile {
                    cacheService?.upsertProfile(snapshotProfile)
                    if appState.currentProfile?.id == snapshotProfile.id {
                        appState.currentProfile = snapshotProfile
                    }
                }
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                toastManager?.show(message: message, type: .error)
            }
            await registry?.deregister(name)
            throw FamilyServiceError.persistenceFailed("\(errorMessage): \(error)")
        }
    }

    func deleteFamilyAndReset(family: Family) async throws {
        // 1. Delete the CloudKit zone if this user owns it, or add to abandoned queue if offline.
        if appState.isZoneOwner, let zoneID = appState.familyZoneID {
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
        } else {
            cacheService?.clearAll()
        }

        appState.clearSession()
    }
}
