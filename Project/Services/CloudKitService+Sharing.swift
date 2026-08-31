//
//  CloudKitService+Sharing.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation

extension CloudKitService {
    func deleteZone(_ zoneID: CKRecordZone.ID) async throws {
        guard let pvtDB = privateDatabase else {
            throw CloudKitServiceError.accountUnavailable
        }
        _ = try await retrying {
            try await pvtDB.deleteRecordZone(withID: zoneID)
        }
    }

    func ensureZoneExists(_ zoneID: CKRecordZone.ID) async throws {
        guard let pvtDB = privateDatabase else {
            throw CloudKitServiceError.accountUnavailable
        }
        do {
            _ = try await retrying {
                try await pvtDB.recordZone(for: zoneID)
            }

        } catch let error as CloudKitServiceError {
            switch error {
            case .notFound, .zoneNotFound:
                let zone = CKRecordZone(zoneID: zoneID)
                do {
                    _ = try await retrying { () -> CKRecordZone in
                        try await pvtDB.save(zone)
                    }
                } catch {
                    throw CloudKitServiceError.zoneSetupFailed(
                        "Could not set up the family CloudKit zone. Please try again."
                    )
                }
            default:
                throw error
            }
        }
    }

    // MARK: - CKShare Support

    /// Mints a role-targeted share for the family root. The title carries the role token (`"<familyName>:
    /// Hero Invitation"` / `": Co-Parent Invitation"`) that the joiner side parses via
    func createShare(for rootRecordID: CKRecord.ID, role: UserRole) async throws -> CKShare {
        guard let pvtDB = privateDatabase else {
            throw CloudKitServiceError.accountUnavailable
        }
        let serverRoot = try await serverRoot(for: rootRecordID, using: pvtDB)
        let share = CKShare(rootRecord: serverRoot)
        let familyName = (serverRoot["name"] as? String) ?? "Family Guild"
        share[CKShare.SystemFieldKey.title] = "\(familyName)\(role.shareTitleSuffix)"
        // Private share: the public link is not a bearer credential — a
        // participant can join only after the GM adds them via
        // UICloudSharingController.
        share.publicPermission = .none
        _ = try await persistShare(share, with: serverRoot, using: pvtDB)
        // `UICloudSharingController(share:container:)` requires a share already
        // saved to the server; re-fetch so we hand the controller the
        // server-backed instance, not the freshly-minted one.
        return try await fetchSavedShare(forID: share.recordID, using: pvtDB)
    }

    /// Re-fetches a saved share so its server-backed instance is what gets presented.
    private func fetchSavedShare(forID recordID: CKRecord.ID, using pvtDB: CKDatabase) async throws -> CKShare {
        let record = try await retrying {
            try await pvtDB.record(for: recordID)
        }
        guard let share = record as? CKShare else {
            throw CloudKitServiceError.shareFailed(
                "Saved share could not be re-fetched from CloudKit"
            )
        }
        return share
    }

    /// GM-side helper for "the role-specific share I want to present": returns the existing share whose
    /// title carries `role`, or mints one via `createShare(for:role:)`.
    func fetchOrCreateShare(for rootRecordID: CKRecord.ID, role: UserRole) async throws -> CKShare {
        guard let pvtDB = privateDatabase else {
            throw CloudKitServiceError.accountUnavailable
        }
        let targetID = resolveShareTargetID(for: rootRecordID)
        _ = try await serverRoot(for: rootRecordID, using: pvtDB)
        let existing: CKShare?
        do {
            existing = try await roleMatchingShare(in: targetID.zoneID, role: role, using: pvtDB)
        } catch {
            logger.error("Failed to inspect existing \(role.displayName) share: \(error, privacy: .private)")
            throw error
        }
        if let existing {
            let nonOwnerParticipants = existing.participants.filter { $0.role != .owner }
            if nonOwnerParticipants.isEmpty {
                logger.info("Existing \(role.displayName) CKShare in zone '\(targetID.zoneID.zoneName, privacy: .private)' has no remaining participants. Deleting stale share...")
                do {
                    _ = try await pvtDB.deleteRecord(withID: existing.recordID)
                } catch {
                    logger.error("Failed to delete stale share: \(error, privacy: .private)")
                    throw CloudKitServiceError.shareFailed(
                        "Failed to manage the share. Please try again."
                    )
                }
            } else {
                logger.info("Found active \(role.displayName) CKShare in zone '\(targetID.zoneID.zoneName, privacy: .private)'")
                return existing
            }
        }
        logger.info("Minting new \(role.displayName) CKShare in zone '\(targetID.zoneID.zoneName, privacy: .private)'...")
        return try await createShare(for: rootRecordID, role: role)
    }

    /// Resolves the share target's record ID: an explicit family-zone ID is
    /// used as-is; a default-zone ID is translated to the resolved active zone.
    private func resolveShareTargetID(for rootRecordID: CKRecord.ID) -> CKRecord.ID {
        if rootRecordID.zoneID.zoneName != CKRecordZone.default().zoneID.zoneName {
            return rootRecordID
        }
        if let activeZone = activeFamilyZoneID {
            return CKRecord.ID(recordName: rootRecordID.recordName, zoneID: activeZone)
        }
        return rootRecordID
    }

    private func serverRoot(for rootRecordID: CKRecord.ID, using pvtDB: CKDatabase) async throws -> CKRecord {
        try await retrying {
            try await pvtDB.record(for: resolveShareTargetID(for: rootRecordID))
        }
    }

    private func persistShare(_ share: CKShare, with rootRecord: CKRecord, using pvtDB: CKDatabase) async throws -> CKShare {
        do {
            let (savedRecords, _) = try await pvtDB.modifyRecords(
                saving: [rootRecord, share],
                deleting: [],
                savePolicy: .ifServerRecordUnchanged,
                atomically: true
            )
            guard let savedShare = savedRecords[share.recordID], case .success = savedShare else {
                throw CloudKitServiceError.shareFailed(
                    "Could not create the iCloud share. Please try again."
                )
            }
            return share
        } catch let serviceError as CloudKitServiceError {
            throw serviceError
        } catch {
            throw CloudKitServiceError.shareFailed(
                "Could not create the iCloud share. Please try again."
            )
        }
    }

    /// Finds the family's share whose title carries the given role token.
    private func roleMatchingShare(in zoneID: CKRecordZone.ID, role: UserRole, using pvtDB: CKDatabase) async throws -> CKShare? {
        let shares = try await allShares(in: zoneID, using: pvtDB)
        return shares.first { share in
            guard let title = share[CKShare.SystemFieldKey.title] as? String else { return false }
            return UserRole.fromShareTitle(title) == role
        }
    }

    /// Fetches every `CKShare` record in the given zone. A family root can have
    /// multiple role-targeted shares (Hero + Ranger), so all of them are queried.
    private func allShares(in zoneID: CKRecordZone.ID, using pvtDB: CKDatabase) async throws -> [CKShare] {
        let predicate = NSPredicate(value: true)
        let query = CKQuery(recordType: "cloudkit.share", predicate: predicate)

        let matchResults: [(CKRecord.ID, Result<CKRecord, Error>)]
        do {
            (matchResults, _) = try await pvtDB.records(
                matching: query,
                inZoneWith: zoneID,
                resultsLimit: 100
            )
        } catch {
            let wrapped = wrapError(error)
            switch wrapped {
            case .notFound:
                return []
            case let .invalidArguments(msg) where msg.contains("not marked queryable") || msg.contains("not marked indexable") || msg.contains("recordName"):
                return []
            default:
                throw wrapped
            }
        }

        return matchResults.compactMap { _, result in
            guard case let .success(record) = result, let share = record as? CKShare else {
                return nil
            }
            return share
        }
    }

    /// Resolves a share invitation URL into acceptance metadata. Wraps the
    /// container call so callers outside the service layer never touch the
    /// raw container.
    func shareMetadata(for url: URL) async throws -> CKShare.Metadata {
        try await container.shareMetadata(for: url)
    }

    func acceptShare(metadata: CKShare.Metadata) async throws {
        let title = metadata.share[CKShare.SystemFieldKey.title] as? String ?? "Untitled Share"
        logger.info("Accepting share invitation for \(title, privacy: .private)...")
        do {
            _ = try await container.accept(metadata)
            logger.info("Accepted share invitation for \(title, privacy: .private)")
        } catch {
            let code = (error as NSError).domain == CKErrorDomain
                ? CKError.Code(rawValue: (error as NSError).code)
                : nil
            logger.error("Accepting share invitation failed: \(error, privacy: .private)")
            // The raw CloudKit error is logged above with a `.private` annotation and must never reach the
            // user-facing string — keep the accept-failure message static and generic.
            throw CloudKitServiceError.shareAcceptFailed(
                code: code,
                message: "The share invitation could not be accepted."
            )
        }
    }

    func fetchPrivateZones() async throws -> [CKRecordZone] {
        guard let pvtDB = privateDatabase else {
            throw CloudKitServiceError.accountUnavailable
        }
        return try await pvtDB.allRecordZones()
    }

    func fetchSharedZones() async throws -> [CKRecordZone] {
        guard let sharedDB = sharedDatabase else {
            throw CloudKitServiceError.accountUnavailable
        }
        return try await sharedDB.allRecordZones()
    }

    func processAbandonedZonesQueue(appState: AppState) async {
        let queuedNames = appState.abandonedZoneIDs
        guard !queuedNames.isEmpty else { return }

        for zoneName in queuedNames {
            let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
            do {
                try await deleteZone(zoneID)
                appState.removeAbandonedZoneID(zoneName)
                logger.info("Successfully processed abandoned zone deletion: \(zoneName, privacy: .private)")
            } catch {
                logger.error("Retrying abandoned zone deletion failed for \(zoneName, privacy: .private): \(error, privacy: .private)")
            }
        }
    }

    /// Best-effort owner-side revocation: removes a member's participant entry from the family's `CKShare`
    /// so they lose access to the shared zone.
    func removeParticipant(iCloudUserRecordName: String, from rootRecordID: CKRecord.ID) async throws {
        guard let pvtDB = privateDatabase else {
            throw CloudKitServiceError.accountUnavailable
        }
        let targetID = resolveShareTargetID(for: rootRecordID)
        let shares = try await allShares(in: targetID.zoneID, using: pvtDB)

        var revokedAnyShare = false
        for share in shares {
            guard let participant = share.participants.first(where: { $0.userIdentity.userRecordID?.recordName == iCloudUserRecordName })
            else { continue }
            share.removeParticipant(participant)
            let nonOwnerParticipants = share.participants.filter { $0.role != .owner }
            if nonOwnerParticipants.isEmpty {
                logger.info("All non-owner participants removed from CKShare in zone '\(targetID.zoneID.zoneName, privacy: .private)'. Deleting empty share...")
                do {
                    _ = try await pvtDB.deleteRecord(withID: share.recordID)
                } catch {
                    logger.error("Failed to delete empty role share: \(error, privacy: .private)")
                    throw CloudKitServiceError.shareFailed(
                        "Failed to manage the share. Please try again."
                    )
                }
            } else {
                _ = try await persistShare(share, with: serverRoot(for: rootRecordID, using: pvtDB), using: pvtDB)
            }
            revokedAnyShare = true
        }

        guard revokedAnyShare else {
            throw CloudKitServiceError.shareFailed(
                "No role share contains a participant matching this identity — the revocation was not performed"
            )
        }
    }

    /// Aggregates every `CKShare` participant across the family's role shares,
    /// deduplicated by identity (iCloud record name, or email/phone fallback for
    /// not-yet-accepted invites). Drives the in-app Invitations panel.
    func fetchShareParticipants(for rootRecordID: CKRecord.ID) async throws -> [CKShare.Participant] {
        guard let pvtDB = privateDatabase else {
            throw CloudKitServiceError.accountUnavailable
        }
        let targetID = resolveShareTargetID(for: rootRecordID)
        let shares = try await allShares(in: targetID.zoneID, using: pvtDB)

        var seen = Set<String>()
        var participants: [CKShare.Participant] = []
        for share in shares {
            for participant in share.participants {
                guard participant.role != .owner else { continue }
                // Participants with no stable identity key (no record name, email, phone, or participant ID) cannot be
                // matched across fetches and can never be revoked; exclude them rather than surfacing an unrevocable
                guard let key = ShareParticipantKey.key(for: participant) else { continue }
                if seen.insert(key).inserted {
                    participants.append(participant)
                }
            }
        }
        return participants
    }

    /// Testable identity + acceptance summary of every aggregated share participant (see
    /// `fetchShareParticipants` for the deduplication rule).
    func fetchShareParticipantStatuses(for rootRecordID: CKRecord.ID) async throws -> [ShareParticipantStatus] {
        let participants = try await fetchShareParticipants(for: rootRecordID)
        return participants.map { participant in
            ShareParticipantStatus(
                identityKey: ShareParticipantKey.key(for: participant),
                recordName: participant.userIdentity.userRecordID?.recordName,
                isRemoved: participant.acceptanceStatus == .removed
            )
        }
    }

    /// Maps each share participant's stable identity key or record name to the
    /// target `UserRole` decoded from the title of the `CKShare` they belong to.
    func fetchShareParticipantRoles(for rootRecordID: CKRecord.ID) async throws -> [String: UserRole] {
        guard let pvtDB = privateDatabase else { return [:] }
        let targetID = resolveShareTargetID(for: rootRecordID)
        let shares: [CKShare]
        do {
            shares = try await allShares(in: targetID.zoneID, using: pvtDB)
        } catch {
            logger.error("Failed to fetch shares for participant roles: \(error, privacy: .private)")
            throw error
        }

        var rolesByIdentity: [String: UserRole] = [:]
        for share in shares {
            guard let title = share[CKShare.SystemFieldKey.title] as? String,
                  let role = UserRole.fromShareTitle(title) else { continue }
            for participant in share.participants where participant.role != .owner {
                if let key = ShareParticipantKey.key(for: participant) {
                    rolesByIdentity[key] = role
                }
                if let recordName = participant.userIdentity.userRecordID?.recordName {
                    rolesByIdentity[recordName] = role
                }
            }
        }
        return rolesByIdentity
    }

    /// Removes a specific participant (matched by identity, so pending invites without an iCloud record
    /// name can be revoked too) from every matching role share.
    func removeParticipant(_ participant: CKShare.Participant, from rootRecordID: CKRecord.ID) async throws {
        guard let pvtDB = privateDatabase else {
            throw CloudKitServiceError.accountUnavailable
        }
        let targetID = resolveShareTargetID(for: rootRecordID)
        let shares = try await allShares(in: targetID.zoneID, using: pvtDB)

        // Require a stable participant identity key (record name, email, phone, or participant ID).
        guard let key = ShareParticipantKey.key(for: participant) else {
            throw CloudKitServiceError.shareFailed(
                "Cannot revoke a share participant with no CloudKit identity (no user record name, email, phone, or participant ID)"
            )
        }

        var revokedAnyShare = false
        for share in shares {
            guard let match = share.participants.first(where: { ShareParticipantKey.key(for: $0) == key }) else { continue }
            share.removeParticipant(match)
            let nonOwnerParticipants = share.participants.filter { $0.role != .owner }
            if nonOwnerParticipants.isEmpty {
                logger.info("All non-owner participants removed from CKShare in zone '\(targetID.zoneID.zoneName, privacy: .private)'. Deleting empty share...")
                do {
                    _ = try await pvtDB.deleteRecord(withID: share.recordID)
                } catch {
                    logger.error("Failed to delete empty role share: \(error, privacy: .private)")
                    throw CloudKitServiceError.shareFailed(
                        "Failed to manage the share. Please try again."
                    )
                }
            } else {
                _ = try await persistShare(share, with: serverRoot(for: rootRecordID, using: pvtDB), using: pvtDB)
            }
            revokedAnyShare = true
        }

        // The revoke must never be a silent no-op: if no role share contained a
        // matching participant, the revocation truly could not be performed.
        guard revokedAnyShare else {
            throw CloudKitServiceError.shareFailed(
                "No role share contains a participant matching this identity — the revocation was not performed"
            )
        }
    }
}
