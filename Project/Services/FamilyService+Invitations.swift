//
//  FamilyService+Invitations.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import CloudKit
import Foundation

/// Container for resolved invitation link metadata and diagnostic fields.
struct InvitationLinkResolution: Sendable {
    let metadata: CKShare.Metadata
    let title: String
    let zoneName: String
}

// MARK: - Invitation Management

extension FamilyService {
    // MARK: Identity

    /// Resolves the current iCloud user's record name for invitation guards
    /// (prevents revoking self, hides owner rows). Re-resolves fresh on every
    /// call so an OS-level iCloud account change is never masked by a cached
    /// value.
    func currentUserRecordName() async throws -> String {
        try await cloudKit.currentUserRecordID().recordName
    }

    // MARK: Share Operations

    /// Creates or fetches the role-specific `CKShare` for the family. The share
    /// carries `publicPermission = .none` — joining happens only via explicit
    /// participant invites minted through `UICloudSharingController`, not a
    /// public link. Only the zone owner (Guild Master) may mint shares, and the
    /// caller must verify that guard first.
    func prepareInviteShare(for family: Family, role: UserRole) async throws -> CKShare {
        try await cloudKit.fetchOrCreateShare(for: family.id, role: role)
    }

    /// Pairs a prepared invitation share with the container the sharing sheet
    /// needs to register it with `UICloudSharingController`. Assembled here so
    /// views never reach through to the raw CloudKit container.
    func invitePresentation(for share: CKShare) -> CloudSharePresentation {
        CloudSharePresentation(share: share, container: cloudKit.container)
    }

    /// Resolves a pasted invitation link into share acceptance metadata. The
    /// title and zone name ride along so callers can log the resolution
    /// without touching raw CloudKit types; container access stays behind the
    /// service boundary.
    func resolveInvitationLink(_ url: URL) async throws -> InvitationLinkResolution {
        let metadata = try await cloudKit.shareMetadata(for: url)
        let title = metadata.share[CKShare.SystemFieldKey.title] as? String ?? "nil"
        let zoneName = metadata.hierarchicalRootRecordID?.zoneID.zoneName ?? "nil"
        return InvitationLinkResolution(metadata: metadata, title: title, zoneName: zoneName)
    }

    // MARK: Participant Queries

    /// Returns every `CKShare.Participant` entry on the family's root record.
    /// Callers filter active members out of the results to build invitation rows.
    func fetchShareParticipants(for family: Family) async throws -> [CKShare.Participant] {
        try await cloudKit.fetchShareParticipants(for: family.id)
    }

    /// Returns identity-level statuses (including removed markers) so the
    /// invitation panel can flag departed members and already-revoked identities.
    func fetchShareParticipantStatuses(for family: Family) async throws -> [ShareParticipantStatus] {
        try await cloudKit.fetchShareParticipantStatuses(for: family.id)
    }

    /// Returns the role map keyed by identity (record name or identity key)
    /// that was encoded into each share's title at mint time.
    func fetchShareParticipantRoles(for family: Family) async throws -> [String: UserRole] {
        try await cloudKit.fetchShareParticipantRoles(for: family.id)
    }

    // MARK: Revocation

    /// Removes a share participant object from the family's `CKShare`. Only
    /// the zone owner (Guild Master) may revoke — callers must enforce
    /// `appState.isZoneOwner` before calling.
    func revokeInvitation(participant: CKShare.Participant, from family: Family) async throws {
        try await cloudKit.removeParticipant(participant, from: family.id)
    }

    /// Removes a share participant by iCloud record name. Used when only the
    /// identity record name is available (e.g. departed member whose
    /// participant object was lost after deactivation). Only the zone owner
    /// may revoke.
    func revokeInvitation(identityRecordName: String, from family: Family) async throws {
        try await cloudKit.removeParticipant(iCloudUserRecordName: identityRecordName, from: family.id)
    }
}
