//
//  FamilyService+Invitations.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import CloudKit
import Foundation
import UIKit

/// Container for resolved invitation link metadata and diagnostic fields.
struct InvitationLinkResolution: Sendable {
    let metadata: CKShare.Metadata
    let title: String
    let zoneName: String
}

extension InvitationLinkResolution: Equatable {
    static func == (lhs: InvitationLinkResolution, rhs: InvitationLinkResolution) -> Bool {
        lhs.title == rhs.title
            && lhs.zoneName == rhs.zoneName
            && lhs.metadata.share.recordID == rhs.metadata.share.recordID
    }
}

// MARK: - Invitation Management

extension FamilyService {
    // MARK: Identity

    /// Resolves the current iCloud user's record name for invitation guards (prevents revoking self, hides
    /// owner rows).
    func currentUserRecordName() async throws -> String {
        try await cloudKit.currentUserRecordID().recordName
    }

    // MARK: Share Operations

    /// Creates or fetches the role-specific `CKShare` for the family.
    func prepareInviteShare(for family: Family, role: UserRole) async throws -> CKShare {
        try await cloudKit.fetchOrCreateShare(for: family.id, role: role)
    }

    /// Pairs a prepared invitation share with the container the sharing sheet
    /// needs to register it with `UICloudSharingController`. Assembled here so
    /// views never reach through to the raw CloudKit container. The View layer
    /// receives only an opaque provider factory and shareURL.
    func invitePresentation(for share: CKShare) -> CloudSharePresentation {
        let container = cloudKit.container
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

    /// Presentation-only wrapper that keeps `CKShare` in the Service layer.
    /// ViewModels vend this instead of raw `CKShare`.
    func prepareInvitePresentation(for family: Family, role: UserRole) async throws -> CloudSharePresentation {
        let share = try await prepareInviteShare(for: family, role: role)
        return invitePresentation(for: share)
    }

    /// Scans shared zones for a single existing active hero bound to the current
    /// iCloud user. All `CKRecordZone` / `CKRecord.ID` handling stays in the
    /// Service layer; the ViewModel receives only `Family`/`Profile`.
    func detectExistingHeroForJoin() async -> (family: Family, profile: Profile)? {
        let userID: CKRecord.ID
        do {
            userID = try await cloudKit.currentUserRecordID()
        } catch {
            return nil
        }
        let sharedZones: [CKRecordZone]
        do {
            sharedZones = try await cloudKit.fetchSharedZones()
        } catch {
            return nil
        }
        var matches: [(zoneID: CKRecordZone.ID, profile: Profile)] = []
        for zone in sharedZones {
            let zoneID = zone.zoneID
            let activeProfiles = await AppState.activeSharedHeroProfiles(
                cloudKit: cloudKit,
                userRecordID: userID,
                zoneID: zoneID
            )
            for profile in activeProfiles {
                matches.append((zoneID, profile))
            }
        }
        guard matches.count == 1, let match = matches.first else { return nil }
        guard let family = await AppState.sharedZoneFamily(cloudKit: cloudKit, zoneID: match.zoneID) else { return nil }
        return (family, match.profile)
    }

    /// Creates a family with onboarding-supplied display values. The `Profile`
    /// construction (including `CKRecord.ID`/`CKRecord.Reference`) stays in the
    /// Service layer so the ViewModel never spells CloudKit types.
    func createFamilyWithOnboarding(
        name: String,
        displayName: String,
        avatarClass: AvatarClass?,
        avatarPresetID: String?,
        customAvatarImageData: Data?,
        avatarEmoji: String?
    ) async throws -> (family: Family, profile: Profile) {
        let ownerID = try await cloudKit.currentUserRecordID()
        let ownerProfile = Profile(
            displayName: displayName,
            avatarClass: avatarClass,
            avatarPresetID: avatarPresetID,
            customAvatarImageData: customAvatarImageData,
            role: .guildMaster,
            iCloudUserID: ownerID,
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: "pending"), action: .none),
            avatarEmoji: avatarEmoji
        )
        return try await createFamily(name: name, ownerProfile: ownerProfile)
    }

    /// Resolves a pasted invitation link into share acceptance metadata.
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

    /// Removes a share participant by iCloud record name. Used when only the identity record name is
    /// available (e.g.
    func revokeInvitation(identityRecordName: String, from family: Family) async throws {
        try await cloudKit.removeParticipant(iCloudUserRecordName: identityRecordName, from: family.id)
    }
}
