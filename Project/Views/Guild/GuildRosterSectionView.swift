//
//  GuildRosterSectionView.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import CloudKit
import os
import SwiftUI

struct GuildRosterSectionView: View {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "GuildRosterSection")

    @Bindable var viewModel: FamilyDashboardViewModel
    let onRebuild: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(FamilyService.self) private var familyService
    @Environment(QuestService.self) private var questService
    @Environment(ToastManager.self) private var toastManager

    @Binding var heroToEdit: ProfileCache?
    @Binding var showRoleTransferConfirm: ProfileCache?
    @Binding var isRoleTransferConfirmPresented: Bool

    @State private var memberToKick: ProfileCache?
    @State private var invitationToRevoke: FamilyInvitation?

    var body: some View {
        VStack(spacing: 18) {
            membersSection
            if appState.currentProfile?.role == .guildMaster {
                invitationsSection
            }
        }
    }

    private var membersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Members")
                    .font(.headline)
                Spacer()
                Text("\(viewModel.heroes.count + viewModel.parents.count)")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)

            VStack(spacing: 0) {
                ForEach(viewModel.parents) { member in
                    memberRow(member)
                    Divider().padding(.leading, 56)
                }
                ForEach(viewModel.heroes) { member in
                    memberRow(member)
                    Divider().padding(.leading, 56)
                }
            }
            .background(cardBackground)
            .padding(.horizontal)
            .alert("Remove \(memberToKick?.displayName ?? "Member")?", isPresented: Binding(
                get: { memberToKick != nil },
                set: {
                    if !$0 {
                        memberToKick = nil
                    }
                }
            )) {
                Button("Remove", role: .destructive) {
                    if let member = memberToKick {
                        Task { await kickMember(member) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This member will lose access to all quests, earnings history, and weekly allowances.")
            }
        }
    }

    private var invitationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Invitations")
                    .font(.headline)
                Spacer()
                if !viewModel.invitations.isEmpty {
                    Text("\(viewModel.invitations.count)")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)

            if viewModel.invitations.isEmpty {
                Text("No pending invitations")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(cardBackground)
                    .padding(.horizontal)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.invitations.enumerated()), id: \.element.id) { index, invitation in
                        invitationRow(invitation)
                        if index < viewModel.invitations.count - 1 {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
                .background(cardBackground)
                .padding(.horizontal)
            }
        }
        .alert("Revoke \(invitationToRevoke?.identity ?? "Invitation")?",
               isPresented: Binding(
                   get: { invitationToRevoke != nil },
                   set: {
                       if !$0 {
                           invitationToRevoke = nil
                       }
                   }
               )) {
            Button("Revoke", role: .destructive) {
                if let invitation = invitationToRevoke {
                    Task { await viewModel.revokeInvitation(invitation) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(revokeConfirmationMessage)
        }
    }

    private var revokeConfirmationMessage: String {
        switch invitationToRevoke?.kind {
        case .departedMember:
            "This member already left the guild. Revoking removes their remaining share access so they can no longer read this family's data."
        case .pendingInvite:
            "This invitation has not been accepted. Revoking it will prevent this person from joining the guild."
        default:
            "This will remove the member's access to the guild."
        }
    }

    private func invitationRow(_ invitation: FamilyInvitation) -> some View {
        HStack(spacing: 12) {
            Image(systemName: Self.invitationIcon(for: invitation.kind))
                .font(.title3)
                .foregroundStyle(Self.invitationTint(for: invitation.kind))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(invitation.identity)
                        .font(.body.weight(.semibold))

                    if let role = invitation.targetRole {
                        roleBadge(for: role)
                    }
                }
                Text(invitation.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if invitation.kind != .removedIdentity {
                Button(role: .destructive) {
                    invitationToRevoke = invitation
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.revokeInvite-\(invitation.id)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func roleBadge(for role: UserRole) -> some View {
        HStack(spacing: 4) {
            Image(systemName: role.iconSystemName)
                .font(.caption2.weight(.bold))
            Text(role.displayName)
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(role == .ranger ? Color.gold.opacity(0.20) : Color.blue.opacity(0.15))
        )
        .foregroundStyle(role == .ranger ? Color.gold : Color.blue)
    }

    private static func invitationIcon(for kind: FamilyInvitationKind) -> String {
        switch kind {
        case .pendingInvite: "envelope.fill"
        case .departedMember: "person.fill.xmark"
        case .removedIdentity: "person.crop.circle.badge.xmark"
        }
    }

    private static func invitationTint(for kind: FamilyInvitationKind) -> Color {
        switch kind {
        case .pendingInvite: .blue
        case .departedMember: .orange
        case .removedIdentity: .secondary
        }
    }

    private func memberRow(_ member: ProfileCache) -> some View {
        let role = member.roleEnum ?? .hero
        return HStack(spacing: 12) {
            memberAvatarView(member)
            VStack(alignment: .leading, spacing: 2) {
                Text(member.displayName)
                    .font(.body.weight(.semibold))
                Text(role.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            roleManagementMenu(member)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func memberAvatarView(_ member: ProfileCache) -> some View {
        ProfileAvatarView(profileCache: member)
    }

    @ViewBuilder
    private func roleManagementMenu(_ member: ProfileCache) -> some View {
        let isCurrent = appState.currentProfile?.id.recordName == member.recordName
        let role = member.roleEnum
        if appState.currentProfile?.role == .guildMaster, !isCurrent {
            Menu {
                if role == .hero {
                    Button {
                        heroToEdit = member
                    } label: {
                        Label("Hero Settings…", systemImage: "slider.horizontal.3")
                    }
                } else if role == .ranger {
                    Button {
                        showRoleTransferConfirm = member
                        isRoleTransferConfirmPresented = true
                    } label: {
                        Label("Transfer Guild Master…", systemImage: "crown.fill")
                    }
                }

                Divider()

                Button(role: .destructive) {
                    memberToKick = member
                } label: {
                    Label("Remove from Guild", systemImage: "person.crop.circle.badge.xmark")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.tint)
            }
            .accessibilityIdentifier("settings.roleMenu-\(member.recordName)")
        } else if isCurrent {
            Text("You")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @MainActor
    private func kickMember(_ member: ProfileCache) async {
        let zoneID = appState.familyZoneID ?? appState.family?.id.zoneID ?? member.validatedZoneID(requestedZoneID: CKRecordZone.default().zoneID)
        do {
            let result = try await familyService.kickMember(profile: member.toProfile(zoneID: zoneID))
            await viewModel.refresh()
            onRebuild()
            if case .partialRevocationFailed = result {
                toastManager.show(
                    message: "Member removed, but their share access could not be revoked. Revoke it in Invitations.",
                    type: .error
                )
            }
        } catch {
            logger.error("Failed to remove member: \(error, privacy: .private)")
            toastManager.show(message: "Could not remove the member. Please try again.", type: .error)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(.secondarySystemGroupedBackground))
    }
}
