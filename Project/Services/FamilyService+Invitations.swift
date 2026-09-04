//
//  FamilyService+Invitations.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import CloudKit
import Foundation
import Synchronization

/// Sendable snapshot of an accepted invitation; View state holds only this.
/// WHY snapshot: `CKShare.Metadata` is a non-Sendable NSObject, so the View
/// layer keeps title/zone/share identity while the Service layer re-resolves
/// acceptance from the stashed object at join time.
struct InvitationLinkResolution: Sendable, Equatable, Hashable {
    let title: String?
    let zoneName: String?
    let zoneOwnerName: String?
    let rootRecordName: String?
    let shareRecordName: String

    // WHY: zone/owner/root rebuild the join target without keeping the acceptance object in View state.
    var zoneID: CKRecordZone.ID? {
        guard let zoneName, let zoneOwnerName else { return nil }
        return CKRecordZone.ID(zoneName: zoneName, ownerName: zoneOwnerName)
    }

    var rootRecordID: CKRecord.ID? {
        guard let rootRecordName, let zoneID else { return nil }
        return CKRecord.ID(recordName: rootRecordName, zoneID: zoneID)
    }
}

extension InvitationLinkResolution {
    @MainActor
    init(metadata: CKShare.Metadata) {
        self.title = metadata.share[CKShare.SystemFieldKey.title] as? String
        self.zoneName = metadata.hierarchicalRootRecordID?.zoneID.zoneName
        self.zoneOwnerName = metadata.hierarchicalRootRecordID?.zoneID.ownerName
        self.rootRecordName = metadata.hierarchicalRootRecordID?.recordName
        self.shareRecordName = metadata.share.recordID.recordName
        // WHY: stash the non-Sendable acceptance alongside its snapshot so join re-resolves it inside the Service layer.
        InvitationMetadataStore.stash(metadata)
    }
}

/// Service-side retention for acceptance objects keyed by share identity.
@MainActor
enum InvitationMetadataStore {
    // WHY: Confined to @MainActor so non-Sendable CKShare.Metadata is safely stored without @unchecked Sendable or locks.
    private static var order: [String] = []
    private static var entries: [String: CKShare.Metadata] = [:]
    private static let maxStashed = 5

    static func stash(_ metadata: CKShare.Metadata) {
        let key = metadata.share.recordID.recordName
        // WHY: scene and app-delegate callbacks can deliver the same acceptance twice, so the replay fires once per share.
        if entries[key] != nil {
            order.removeAll { $0 == key }
        } else if order.count >= maxStashed, let oldest = order.first {
            // WHY: cap bounds cold-launch replay when repeated invite taps arrive before join consumes them.
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
        order.append(key)
        entries[key] = metadata
    }

    static func metadata(for resolution: InvitationLinkResolution) -> CKShare.Metadata? {
        entries[resolution.shareRecordName]
    }

    static func remove(for resolution: InvitationLinkResolution) {
        remove(shareRecordName: resolution.shareRecordName)
    }

    static func remove(shareRecordName key: String) {
        entries.removeValue(forKey: key)
        order.removeAll { $0 == key }
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
            logger.debug("Join hero detection aborted: unable to resolve currentUserRecordID: \(error, privacy: .private)")
            return nil
        }
        let sharedZones: [CKRecordZone]
        do {
            sharedZones = try await cloudKit.fetchSharedZones()
        } catch {
            logger.debug("Join hero detection aborted: unable to fetchSharedZones: \(error, privacy: .private)")
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
        return InvitationLinkResolution(metadata: metadata)
    }

    /// Joins via a View-held snapshot, re-resolving the stashed acceptance inside the Service layer.
    /// WHY snapshot join: View state never holds the non-Sendable acceptance object, so the snapshot carries
    /// share identity and the Service layer maps it back to the stashed object at join time.
    func joinFamilyViaAcceptedShare(resolution: InvitationLinkResolution?,
                                    displayName: String?,
                                    avatarClass: AvatarClass?,
                                    progressHandler: ((String, Double) -> Void)? = nil) async throws -> JoinedFamilyResult
    {
        // WHY fail-closed on stash miss: falling back to the first shared zone could join the wrong family.
        guard let resolution, let metadata = InvitationMetadataStore.metadata(for: resolution) else {
            throw CloudKitServiceError.shareFailed("The invitation could not be found — ask the Guild Master for a new invite link")
        }
        let result = try await joinFamilyViaAcceptedShare(metadata: metadata,
                                                          displayName: displayName,
                                                          avatarClass: avatarClass,
                                                          progressHandler: progressHandler)
        // WHY: join consumed the stashed acceptance, so evict it to bound retention.
        InvitationMetadataStore.remove(for: resolution)
        return result
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

    /// Removes a share participant by iCloud record name when the full participant object was never
    /// fetched (e.g. pending email/phone identity-key rows surfaced by the invitations panel).
    func revokeInvitation(identityRecordName: String, from family: Family) async throws {
        try await cloudKit.removeParticipant(iCloudUserRecordName: identityRecordName, from: family.id)
    }
}
