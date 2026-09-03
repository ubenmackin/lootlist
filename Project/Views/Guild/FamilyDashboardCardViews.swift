//
//  FamilyDashboardCardViews.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import SwiftUI

struct DashboardChildCardContent: View {
    let card: ChildAccountCard
    let minHeight: CGFloat?
    let isRegular: Bool

    var body: some View {
        VStack(spacing: 8) {
            if let emoji = card.profile.avatarEmoji, !emoji.isEmpty {
                Text(emoji)
                    .font(.system(size: 36))
                    .frame(width: 48, height: 48)
                    .background(
                        Circle()
                            .fill(Color(DesignSystemConstants.Colors.cardSurface))
                    )
            } else {
                ProfileAvatarView(profileCache: card.profile)
                    .frame(width: 48, height: 48)
            }

            Text(card.profile.displayName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text("\(CurrencyFormatter.string(card.balance)) available")
                .font(.caption2.weight(.medium).monospacedDigit())
                .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))

            if card.pendingReviewCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.caption2)
                    Text("\(card.pendingReviewCount) pending")
                        .font(.caption2.weight(.medium))
                }
                .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.15))
                )
            }

            Spacer(minLength: 0)

            Text(isRegular ? "Inspect" : "View Screen")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: ChildCardHeightPreferenceKey.self,
                    value: geo.size.height
                )
            }
        )
        .frame(minHeight: minHeight)
        .padding(DesignSystemConstants.Padding.medium)
        .background(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small, style: .continuous)
                .fill(Color(DesignSystemConstants.Colors.cardSurface))
        )
        .hoverEffect(.highlight)
    }
}

struct DashboardEmptyChildrenCard: View {
    let isGuildMaster: Bool

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.15))
                    .frame(width: 64, height: 64)
                Image(systemName: "person.badge.plus")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))
            }

            VStack(spacing: 6) {
                Text("Recruit Your Party!")
                    .font(.title3.weight(.heavy))
                Text(isGuildMaster
                    ? "Your guild needs heroes to embark on quests. Tap **Invite Members** above to invite a Hero to your guild."
                    : "Your guild needs heroes to embark on quests. Ask the Guild Master to invite a Hero to your guild.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DesignSystemConstants.Padding.medium)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignSystemConstants.Padding.xlarge)
        .padding(.horizontal, DesignSystemConstants.Padding.standard)
        .background(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.header, style: .continuous)
                .fill(Color(DesignSystemConstants.Colors.cardSurface))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.header, style: .continuous)
                .strokeBorder(Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.35), lineWidth: 1.5)
        )
    }
}

struct DashboardQuickActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
                    .font(.subheadline.weight(.bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignSystemConstants.Padding.medium)
            .background(
                RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small, style: .continuous)
                    .fill(Color(DesignSystemConstants.Colors.cardSurface))
            )
            .foregroundStyle(color)
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small, style: .continuous)
                    .strokeBorder(color.opacity(0.4), lineWidth: 1)
            )
        }
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }
}

struct DashboardStatBlock: View {
    let icon: String
    let value: String
    let label: String
    let tint: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(tint)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct DashboardTotalsRow: View {
    let summary: WeekendSummary
    let isPending: Bool

    var body: some View {
        HStack(spacing: 12) {
            DashboardStatBlock(
                icon: isPending ? "hourglass" : "banknote",
                value: CurrencyFormatter.string(isPending ? summary.pendingPayoutAmount : summary.totalEarned),
                label: isPending ? "Pending" : "Earned",
                tint: isPending ? Color(DesignSystemConstants.Colors.pendingAmber) : Color(DesignSystemConstants.Colors.primaryGreen)
            )
            Divider()
            DashboardStatBlock(
                icon: "checkmark.circle.fill",
                value: "\(summary.totalQuestsCompleted)",
                label: "Quests",
                tint: Color(DesignSystemConstants.Colors.primaryGreen)
            )
            Divider()
            DashboardStatBlock(
                icon: "person.2.fill",
                value: "\(summary.heroSummaries.count)",
                label: "Heroes",
                tint: Color(DesignSystemConstants.Colors.accentBlue)
            )
        }
        .frame(maxWidth: .infinity)
    }
}

struct DashboardLoadingPlaceholder: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "house")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
                .padding(.top, 120)
            Text("Summoning your guild…")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct DashboardInviteButton: View {
    @Binding var showRolePicker: Bool

    var body: some View {
        Button {
            showRolePicker = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.badge.plus")
                    .font(.caption.weight(.bold))
                Text("Invite")
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color(DesignSystemConstants.Colors.cardSurface))
                    .overlay(
                        Capsule().strokeBorder(Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.45), lineWidth: 1)
                    )
            )
        }
        .accessibilityLabel("Invite Members. Tap to invite a Hero or Co-Parent.")
        .accessibilityIdentifier("dashboard.inviteButton")
    }
}
