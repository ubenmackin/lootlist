//
//  FamilyInvitationCoordinator.swift
//  LootList
//
//  Created by Ben Mackin on 8/29/26.
//

import Foundation
import os

/// Orchestrates share invitation flows for the family dashboard.
/// ViewModels never hold `any CloudKitServiceProtocol` directly — they route
/// through `FamilyService`/`TreasuryService`. This coordinator is the sole
/// invitation seam behind `FamilyInviting` so `FamilyDashboardViewModel` stays
/// pure `rebuildLists` + bindings. CKShare stays in the Service layer; the
/// coordinator vends only presentation objects.
@MainActor
protocol FamilyInviting: Sendable {
    func prepareInviteShare(for role: UserRole) async -> CloudSharePresentation?
    func refreshInvitations(
        heroes: [ProfileCache],
        parents: [ProfileCache]
    ) async -> [FamilyInvitation]
    func revokeInvitation(_ invitation: FamilyInvitation) async throws
}

@MainActor
final class FamilyInvitationCoordinator: FamilyInviting {
    private let familyService: any FamilyProfileFetching
    private let appState: AppState
    private let invitationResolver: InvitationResolver
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "FamilyInvitationCoordinator")

    init(
        familyService: any FamilyProfileFetching,
        appState: AppState,
        invitationResolver: InvitationResolver = InvitationResolver()
    ) {
        self.familyService = familyService
        self.appState = appState
        self.invitationResolver = invitationResolver
    }

    /// Resolves role-specific share presentation via FamilyService (zone owner only).
    func prepareInviteShare(for role: UserRole) async -> CloudSharePresentation? {
        guard appState.isZoneOwner,
              appState.familyZoneID != nil,
              let family = appState.family
        else { return nil }
        do {
            return try await familyService.prepareInvitePresentation(for: family, role: role)
        } catch {
            logger.error("Failed to fetch or create invitation share: \(error, privacy: .private)")
            return nil
        }
    }

    /// Reloads and classifies invitation statuses from the family's share
    /// participants. All CloudKit interaction is routed through `FamilyService`
    /// so the caller never holds a raw CloudKit reference.
    func refreshInvitations(
        heroes: [ProfileCache],
        parents: [ProfileCache]
    ) async -> [FamilyInvitation] {
        guard appState.isZoneOwner, let family = appState.family else {
            return []
        }
        var currentUserRecordName: String
        do {
            currentUserRecordName = try await familyService.currentUserRecordName()
        } catch {
            logger.warning("Failed to resolve current user record ID for invitation refresh: \(error, privacy: .private)")
            return []
        }

        var activeRecordNames = Set((heroes + parents).map(\.iCloudUserRecordName))
        let inactiveIdentities = await departedMemberIdentities(for: family)

        let statuses: [ShareParticipantStatus]
        do {
            statuses = try await familyService.fetchShareParticipantStatuses(for: family)
        } catch {
            logger.error("Failed to load share participant statuses: \(error, privacy: .private)")
            return []
        }

        let roleMap: [String: UserRole]
        do {
            roleMap = try await familyService.fetchShareParticipantRoles(for: family)
        } catch {
            logger.warning("Failed to fetch share participant roles: \(error, privacy: .private)")
            roleMap = [:]
        }

        await reconcileMissingAcceptedMembers(
            for: family,
            statuses: statuses,
            currentUserRecordName: currentUserRecordName,
            activeRecordNames: &activeRecordNames
        )

        await invitationResolver.computeIdentityLabels(from: statuses)

        return await invitationResolver.assembleInvitations(
            statuses: statuses,
            currentUserRecordName: currentUserRecordName,
            activeRecordNames: activeRecordNames,
            inactiveIdentities: inactiveIdentities,
            roleMap: roleMap
        )
    }

    /// Revokes a pending invitation or departed member's share access.
    /// Fail-closed: every guard throws so the panel never reports success when
    /// revocation never ran.
    func revokeInvitation(_ invitation: FamilyInvitation) async throws {
        guard appState.isZoneOwner, let family = appState.family else {
            throw FamilyServiceError.unauthorized
        }
        if invitation.kind == .removedIdentity {
            logger.error("Refusing to revoke an already-removed identity — nothing to revoke")
            throw CloudKitServiceError.shareFailed("This invitation was already removed — refresh invitations and try again")
        }
        if invitation.isOwner {
            logger.error("Refusing to revoke the share owner's access")
            throw FamilyServiceError.unauthorized
        }
        // WHY: record-backed rows still guard self-revocation by record name, then delegate to the stable identity-key path.
        if let identityRecordName = invitation.identityRecordName {
            let currentUserRecordName: String
            do {
                currentUserRecordName = try await familyService.currentUserRecordName()
            } catch {
                logger.warning("Failed to resolve current user record ID for revocation guard: \(error, privacy: .private)")
                throw CloudKitServiceError.shareFailed("Could not verify the current user — the revocation was not performed")
            }
            if identityRecordName == currentUserRecordName {
                logger.error("Refusing to revoke the current user's own share access")
                throw FamilyServiceError.unauthorized
            }
        }

        // WHY: key miss falls back to record name; any other key-path error rethrows so transient failures never mask behind a second fetch.
        if let identityKey = invitation.identityKey, !identityKey.isEmpty {
            do {
                try await familyService.revokeInvitation(identityKey: identityKey, from: family)
                return
            } catch let error as CloudKitServiceError {
                guard case let .shareFailed(message) = error, message.contains("No role share contains") else { throw error }
                guard let recordName = invitation.identityRecordName, !recordName.isEmpty else { throw error }
                try await familyService.revokeInvitation(identityRecordName: recordName, from: family)
                return
            }
        }
        // WHY: key-absent rows still revoke by record name when available.
        if let recordName = invitation.identityRecordName, !recordName.isEmpty {
            try await familyService.revokeInvitation(identityRecordName: recordName, from: family)
            return
        }
        // WHY: no identity on the row — delegate to the key path so the single-source error surfaces.
        try await familyService.revokeInvitation(identityKey: "", from: family)
    }

    // MARK: - Private helpers

    private func reconcileMissingAcceptedMembers(
        for family: Family,
        statuses: [ShareParticipantStatus],
        currentUserRecordName: String,
        activeRecordNames: inout Set<String>
    ) async {
        let missingAcceptedMembers = statuses.contains { status in
            guard let recordName = status.recordName,
                  !status.isRemoved,
                  recordName != currentUserRecordName else { return false }
            return !activeRecordNames.contains(recordName)
        }

        guard missingAcceptedMembers else { return }

        await familyService.refreshProfilesFromCloudKit(for: family)
        do {
            let fresh = try await familyService.fetchAllProfilesForFamily(family)
            let freshActive = fresh.filter(\.isActive)
            activeRecordNames.formUnion(Set(freshActive.map(\.iCloudUserID.recordName)))
        } catch {
            logger.warning("FamilyDashboard roster reconciliation skipped: \(error, privacy: .private)")
        }
    }

    /// Maps deactivated member identity record names to display names (best-effort).
    private func departedMemberIdentities(for family: Family) async -> [String: String] {
        let profiles: [Profile]
        do {
            profiles = try await familyService.fetchAllProfilesForFamily(family)
        } catch {
            logger.warning("Failed to fetch all profiles for family: \(error, privacy: .private)")
            return [:]
        }
        var identities: [String: String] = [:]
        for profile in profiles where !profile.isActive && !profile.iCloudUserID.recordName.isEmpty {
            identities[profile.iCloudUserID.recordName] = profile.displayName
        }
        return identities
    }
}
