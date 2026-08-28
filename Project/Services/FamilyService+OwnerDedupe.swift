//
//  FamilyService+OwnerDedupe.swift
//  LootList
//
//  Created by Ben Mackin on 8/11/26.
//

import CloudKit
import Foundation

extension FamilyService {
    // MARK: - Owner-Side Identity Dedupe (Guild Master re-onboarding)

    /// Finds existing owner family matching server-stamped creatorUserRecordName.
    func findExistingOwnerFamily(currentUserRecordName: String) async throws -> (family: Family, zoneID: CKRecordZone.ID)? {
        let privateZones: [CKRecordZone] = try await cloudKit.fetchPrivateZones()

        let customZones = privateZones.filter { $0.zoneID.zoneName != "_defaultZone" && $0.zoneID.zoneName != "LootListZone" }
        let db = cloudKit.privateDatabase

        for zone in customZones {
            let familyID = CKRecord.ID(recordName: zone.zoneID.zoneName, zoneID: zone.zoneID)
            let family: Family
            do {
                family = try await cloudKit.fetch(Family.self, id: familyID, using: db)
            } catch let error as CloudKitServiceError {
                // Fail-closed: only `notFound` proceeds to the next zone; any
                // transient error rethrows rather than risking a duplicate.
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

    /// Resolves Guild Master profile for reused owner family: active reuse, reactivation, or fresh mint.
    func resolveExistingOwnerProfile(in zoneID: CKRecordZone.ID,
                                     family: Family,
                                     ownerProfile ownerOnboarding: Profile) async throws -> Profile
    {
        let db = cloudKit.privateDatabase
        let creatorID = CKRecord.ID(recordName: family.createdBy.recordName, zoneID: zoneID)
        do {
            // `fetch` throws on absence, so the provable-absence vs error split
            // is made in the catch (fail-closed) rather than via optional try.
            let fetched: Profile = try await cloudKit.fetch(Profile.self, id: creatorID, using: db)
            if fetched.isActive {
                logger.info("Direct point lookup found active Guild Master profile: '\(fetched.displayName, privacy: .private)'")
                return fetched
            }
            // Inactive GM: reactivate preserving the existing identity.
            logger.info("Direct point lookup found inactive Guild Master profile '\(fetched.displayName, privacy: .private)'; reactivating")
            return try await reactivateOrSaveOwner(fetched, in: zoneID, family: family, using: db)
        } catch let error as CloudKitServiceError {
            // Fail-closed: only `notFound` falls through to the query fallback.
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
            throw FamilyServiceError.creationFailed
        }
        // Prefer the family's actual creator to repair the original identity
        // rather than minting a parallel GM.
        let existingGM = profiles.first(where: { $0.role == .guildMaster && $0.id == creatorID })
            ?? profiles.first(where: { $0.role == .guildMaster })
            ?? profiles.first(where: { $0.isActive })
        if let gm = existingGM {
            if gm.isActive {
                logger.info("Query fallback found active Guild Master profile: '\(gm.displayName, privacy: .private)'")
                return gm
            }
            logger.info("Query fallback found inactive Guild Master profile '\(gm.displayName, privacy: .private)'; reactivating")
            return try await reactivateOrSaveOwner(gm, in: zoneID, family: family, using: db)
        }
        // No GM at all: mint a fresh one in the existing zone (no duplicate Family).
        logger.info("No existing Guild Master profile found in reused family zone; creating fresh GM")
        return try await reactivateOrSaveOwner(ownerOnboarding, in: zoneID, family: family, using: db, forceCreate: true)
    }

    /// Saves or reactivates existing Guild Master profile during owner family reuse.
    func reactivateOrSaveOwner(_ profile: Profile,
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
        owner.isActive = true
        do {
            let saved = try await cloudKit.save(owner, in: zoneID, using: db)
            await cacheService?.upsertProfile(saved)
            return saved
        } catch {
            throw FamilyServiceError.creationFailed
        }
    }

    /// Persists resolved family session state to AppState and activates owner scope.
    func finalizeOwnerSession(family: Family,
                              profile: Profile,
                              zoneID: CKRecordZone.ID) -> OwnerSessionResult
    {
        appState.family = family
        appState.currentProfile = profile
        appState.familyZoneID = zoneID
        appState.isZoneOwner = true
        cloudKit.activeFamilyZoneID = zoneID
        cloudKit.activeIsOwner = true
        appState.saveSession(profile: profile, family: family, zoneID: zoneID, isOwner: true)
        return OwnerSessionResult(family: family, profile: profile)
    }
}
