//
//  InviteRolePickerView.swift
//  LootList
//
//  Created by Ben Mackin on 8/11/26.
//

import SwiftUI

/// Premium invitation role picker sheet presented by the Guild Master to choose
/// whether an invitation targets a Hero (child profile) or a Co-Parent (Ranger).
struct InviteRolePickerView: View {
    let onSelect: (UserRole) async -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Invite Members")
                        .font(.system(size: 22, weight: .bold, design: .rounded))

                    Text("Select the role for this family invitation")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(.top, 4)

            VStack(spacing: 12) {
                RoleOptionCard(
                    role: .hero,
                    title: "Hero",
                    subtitle: "For kids & dependents — complete quests, earn money & rewards",
                    iconName: "figure.and.child.holdinghands",
                    gradientColors: [Color(DesignSystemConstants.Colors.accentBlue), Color(DesignSystemConstants.Colors.accentBlue)]
                ) {
                    select(.hero)
                }

                RoleOptionCard(
                    role: .ranger,
                    title: "Ranger",
                    subtitle: "For co-parents & guardians — manage quests, approve payouts & settings",
                    iconName: "person.2.fill",
                    gradientColors: [Color.gold, Color(DesignSystemConstants.Colors.pendingAmber)]
                ) {
                    select(.ranger)
                }
            }
        }
        .padding(20)
        .presentationDetents([.height(310)])
        .presentationCornerRadius(28)
        .presentationDragIndicator(.visible)
    }

    private func select(_ role: UserRole) {
        dismiss()
        Task { await onSelect(role) }
    }
}

/// Custom interactive selection card for the role picker
private struct RoleOptionCard: View {
    let role: UserRole
    let title: String
    let subtitle: String
    let iconName: String
    let gradientColors: [Color]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                // Icon Badge Container
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: gradientColors.map { $0.opacity(0.18) },
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 48, height: 48)

                    Image(systemName: iconName)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: gradientColors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

                // Text info
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)

                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
