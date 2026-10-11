//
//  CloudKitService+Sharing.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import Synchronization

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

    /// Mints the family's single share for the family root. The title carries display-only role copy
    /// (`role.shareTitleSuffix`); joins are share-agnostic — fresh profiles mint as `.hero`, reactivations
    /// preserve the stored role and record name, and later changes go only through `updateMemberRole`.
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

    /// GM-side helper for the family's single share: returns the existing share
    /// resolved from the root, or mints one via `createShare(for:role:)` when none exists.
    func fetchOrCreateShare(for rootRecordID: CKRecord.ID, role: UserRole) async throws -> CKShare {
        guard let pvtDB = privateDatabase else {
            throw CloudKitServiceError.accountUnavailable
        }
        let targetID = resolveShareTargetID(for: rootRecordID)
        let root = try await serverRoot(for: rootRecordID, using: pvtDB)
        let existing: CKShare?
        do {
            existing = try await resolveFamilyShare(root: root, using: pvtDB)
        } catch {
            logger.error("Failed to inspect existing \(role.displayName) share: \(error, privacy: .private)")
            throw error
        }
        if let existing {
            if existing.publicPermission != .none {
                logger.info("Correcting \(role.displayName) CKShare publicPermission to .none in zone '\(targetID.zoneID.zoneName, privacy: .private)'")
                return try await correctSharePermissionToNone(existing, root: root, using: pvtDB)
            }
            // Reuse even with no non-owner participants — rotating the share would invalidate previously sent links.
            logger.info("Found \(role.displayName) CKShare in zone '\(targetID.zoneID.zoneName, privacy: .private)' — reusing existing share")
            return existing
        }
        logger.info("Minting new \(role.displayName) CKShare in zone '\(targetID.zoneID.zoneName, privacy: .private)'...")
        return try await createShare(for: rootRecordID, role: role)
    }

    /// Saving a share with .none drops every participant server-side, so the
    /// re-add set is resolved before the save wipes anything: a fetch failure
    /// leaves the share untouched instead of stranded participant-less.
    private func correctSharePermissionToNone(_ share: CKShare, root: CKRecord, using pvtDB: CKDatabase) async throws -> CKShare {
        var lookupInfos: [CKUserIdentity.LookupInfo] = []
        for participant in share.participants where participant.role != .owner {
            guard let lookup = singleLookup(for: participant) else {
                throw CloudKitServiceError.shareFailed(
                    "Could not preserve share participants while correcting permissions. Please try again."
                )
            }
            lookupInfos.append(lookup)
        }
        guard !lookupInfos.isEmpty else {
            share.publicPermission = .none
            _ = try await persistShare(share, with: root, using: pvtDB)
            return try await fetchSavedShare(forID: share.recordID, using: pvtDB)
        }
        let fetched = try await fetchedParticipants(for: lookupInfos)
        share.publicPermission = .none
        _ = try await persistShare(share, with: root, using: pvtDB)
        var refreshed = try await fetchSavedShare(forID: share.recordID, using: pvtDB)
        for participant in fetched {
            participant.permission = .readWrite
            refreshed.addParticipant(participant)
        }
        // The first save advanced the root's change tag, so the atomic second
        // save needs a freshly fetched root.
        let freshRoot = try await serverRoot(for: root.recordID, using: pvtDB)
        _ = try await persistShare(refreshed, with: freshRoot, using: pvtDB)
        refreshed = try await fetchSavedShare(forID: refreshed.recordID, using: pvtDB)
        for lookup in lookupInfos {
            guard hasParticipant(matching: lookup, in: refreshed) else {
                throw CloudKitServiceError.shareFailed(
                    "Could not preserve share participants while correcting permissions. Please try again."
                )
            }
        }
        return refreshed
    }

    /// One lookup per participant: accepted participants round-trip by user
    /// record ID, pending invites by email or phone.
    private func singleLookup(for participant: CKShare.Participant) -> CKUserIdentity.LookupInfo? {
        let identity = participant.userIdentity
        if let recordID = identity.userRecordID {
            return CKUserIdentity.LookupInfo(userRecordID: recordID)
        }
        if let email = identity.lookupInfo?.emailAddress {
            return CKUserIdentity.LookupInfo(emailAddress: email)
        }
        if let phone = identity.lookupInfo?.phoneNumber {
            return CKUserIdentity.LookupInfo(phoneNumber: phone)
        }
        return nil
    }

    private func hasParticipant(matching lookup: CKUserIdentity.LookupInfo, in share: CKShare) -> Bool {
        for participant in share.participants where participant.role != .owner {
            if let wanted = lookup.userRecordID,
               participant.userIdentity.userRecordID == wanted
            {
                return true
            }
            if let wanted = lookup.emailAddress,
               participant.userIdentity.lookupInfo?.emailAddress == wanted
            {
                return true
            }
            if let wanted = lookup.phoneNumber,
               participant.userIdentity.lookupInfo?.phoneNumber == wanted
            {
                return true
            }
        }
        return false
    }

    /// Serial single-identity fetches: each participant travels back over its
    /// own continuation, so concurrent operation callbacks never funnel
    /// non-Sendable values through shared mutable state.
    private func fetchedParticipants(for lookupInfos: [CKUserIdentity.LookupInfo]) async throws -> [CKShare.Participant] {
        var collected: [CKShare.Participant] = []
        collected.reserveCapacity(lookupInfos.count)
        for lookup in lookupInfos {
            try await collected.append(fetchParticipant(for: lookup))
        }
        return collected
    }

    private func fetchParticipant(for lookup: CKUserIdentity.LookupInfo) async throws -> CKShare.Participant {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CKShare.Participant, Error>) in
            // Sendable-only flag: the participant itself is never stored here.
            let resumed = Mutex(false)
            let operation = CKFetchShareParticipantsOperation(userIdentityLookupInfos: [lookup])
            operation.perShareParticipantResultBlock = { _, result in
                let first = resumed.withLock { (done: inout Bool) -> Bool in
                    guard !done else { return false }
                    done = true
                    return true
                }
                guard first else { return }
                switch result {
                case let .success(participant):
                    continuation.resume(returning: participant)
                case .failure:
                    continuation.resume(
                        throwing: CloudKitServiceError.shareFailed(
                            "Could not preserve share participants while correcting permissions. Please try again."
                        )
                    )
                }
            }
            operation.fetchShareParticipantsResultBlock = { _ in
                let first = resumed.withLock { (done: inout Bool) -> Bool in
                    guard !done else { return false }
                    done = true
                    return true
                }
                guard first else { return }
                continuation.resume(
                    throwing: CloudKitServiceError.shareFailed(
                        "Could not preserve share participants while correcting permissions. Please try again."
                    )
                )
            }
            self.container.add(operation)
        }
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

    /// Resolves the family's single share from the root's share reference.
    /// Returns nil only when the root carries no reference. A dangling
    /// reference or any failed re-fetch throws: minting a replacement would
    /// collide with the existing share, so callers fail closed.
    private func resolveFamilyShare(root: CKRecord, using pvtDB: CKDatabase) async throws -> CKShare? {
        guard let reference = root["share"] as? CKRecord.Reference else { return nil }
        do {
            let record = try await retrying {
                try await pvtDB.record(for: reference.recordID)
            }
            guard let share = record as? CKShare else {
                throw CloudKitServiceError.shareFailed(
                    "Could not resolve the iCloud share. Please try again."
                )
            }
            return share
        } catch let serviceError as CloudKitServiceError {
            if case .shareFailed = serviceError {
                throw serviceError
            }
            // WHY fail closed: a second share for one root collides on save, so surface instead of minting.
            throw CloudKitServiceError.shareFailed(
                "Could not resolve the iCloud share. Please try again."
            )
        } catch {
            // WHY fail closed: a second share for one root collides on save, so surface instead of minting.
            throw CloudKitServiceError.shareFailed(
                "Could not resolve the iCloud share. Please try again."
            )
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
        let root = try await serverRoot(for: rootRecordID, using: pvtDB)
        guard let share = try await resolveFamilyShare(root: root, using: pvtDB) else {
            throw CloudKitServiceError.shareFailed(
                "No share contains a participant matching this identity — the revocation was not performed"
            )
        }
        guard let participant = share.participants.first(where: { $0.userIdentity.userRecordID?.recordName == iCloudUserRecordName }) else {
            throw CloudKitServiceError.shareFailed(
                "No share contains a participant matching this identity — the revocation was not performed"
            )
        }
        share.removeParticipant(participant)
        // Keep the empty share so previously sent invite links stay valid.
        _ = try await persistShare(share, with: root, using: pvtDB)
    }

    /// Returns every `CKShare` participant on the family's single share,
    /// deduplicated by identity (iCloud record name, or email/phone fallback for
    /// not-yet-accepted invites). Drives the in-app Invitations panel.
    func fetchShareParticipants(for rootRecordID: CKRecord.ID) async throws -> [CKShare.Participant] {
        guard let pvtDB = privateDatabase else {
            throw CloudKitServiceError.accountUnavailable
        }
        let root = try await serverRoot(for: rootRecordID, using: pvtDB)
        guard let share = try await resolveFamilyShare(root: root, using: pvtDB) else {
            throw CloudKitServiceError.shareFailed(
                "Could not resolve the iCloud share. Please try again."
            )
        }

        var seen = Set<String>()
        var participants: [CKShare.Participant] = []
        for participant in share.participants {
            guard participant.role != .owner else { continue }
            // Participants with no stable identity key (no record name, email, phone, or participant ID) cannot be
            // matched across fetches and can never be revoked; exclude them rather than surfacing an unrevocable
            guard let key = ShareParticipantKey.key(for: participant) else { continue }
            if seen.insert(key).inserted {
                participants.append(participant)
            }
        }
        return participants
    }

    /// Testable identity + acceptance summary of the single share's participants (see
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
    /// target `UserRole` decoded from the title of the family's single `CKShare`.
    func fetchShareParticipantRoles(for rootRecordID: CKRecord.ID) async throws -> [String: UserRole] {
        guard let pvtDB = privateDatabase else { return [:] }
        let root = try await serverRoot(for: rootRecordID, using: pvtDB)
        let share: CKShare?
        do {
            share = try await resolveFamilyShare(root: root, using: pvtDB)
        } catch {
            logger.error("Failed to fetch shares for participant roles: \(error, privacy: .private)")
            throw error
        }
        guard let share else { return [:] }

        // WHY: untitled/legacy shares still grant access, so role decode falls back to .hero instead of dropping the participant.
        let role = UserRole.fromShareTitle(share[CKShare.SystemFieldKey.title] as? String) ?? .hero
        var rolesByIdentity: [String: UserRole] = [:]
        for participant in share.participants where participant.role != .owner {
            if let key = ShareParticipantKey.key(for: participant) {
                rolesByIdentity[key] = role
            }
            if let recordName = participant.userIdentity.userRecordID?.recordName {
                rolesByIdentity[recordName] = role
            }
        }
        return rolesByIdentity
    }

    /// Removes a specific participant (matched by identity, so pending invites without an iCloud record
    /// name can be revoked too) from the family's single share.
    func removeParticipant(_ participant: CKShare.Participant, from rootRecordID: CKRecord.ID) async throws {
        guard let pvtDB = privateDatabase else {
            throw CloudKitServiceError.accountUnavailable
        }
        // Require a stable participant identity key (record name, email, phone, or participant ID).
        guard let key = ShareParticipantKey.key(for: participant) else {
            throw CloudKitServiceError.shareFailed(
                "Cannot revoke a share participant with no CloudKit identity (no user record name, email, phone, or participant ID)"
            )
        }
        let root = try await serverRoot(for: rootRecordID, using: pvtDB)
        guard let share = try await resolveFamilyShare(root: root, using: pvtDB) else {
            throw CloudKitServiceError.shareFailed(
                "No share contains a participant matching this identity — the revocation was not performed"
            )
        }
        guard let match = share.participants.first(where: { ShareParticipantKey.key(for: $0) == key }) else {
            throw CloudKitServiceError.shareFailed(
                "No share contains a participant matching this identity — the revocation was not performed"
            )
        }
        share.removeParticipant(match)
        // Keep the empty share so previously sent invite links stay valid.
        _ = try await persistShare(share, with: root, using: pvtDB)
    }
}
