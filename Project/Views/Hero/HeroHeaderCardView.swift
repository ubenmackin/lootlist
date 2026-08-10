//
//  HeroHeaderCardView.swift
//  LootList
//
//  Created by Ben Mackin on 8/8/26.
//

import CloudKit
import SwiftUI

struct HeroHeaderCardView: View {
    let profile: Profile?
    let familyName: String?
    let streak: Int
    let earnedThisWeek: Double
    let completedQuestCount: Int
    let totalQuestCount: Int
    var isPendingPayout: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerRow
            Divider()
            statsRow
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.gold.opacity(0.30), lineWidth: 1)
        )
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            avatarView

            VStack(alignment: .leading, spacing: 4) {
                Text(profile?.displayName ?? "Hero")
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Text(XPService.title(forLevel: profile?.level ?? 1))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.gold)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                if streak > 0 {
                    StreakBadge(streak: streak, size: .small)
                }

                if let familyName, !familyName.isEmpty {
                    familyNamePill(familyName)
                }
            }
        }
    }

    private var avatarView: some View {
        ProfileAvatarView(profile: profile)
    }

    private func familyNamePill(_ name: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "shield.fill")
                .font(.caption2)
            Text(name)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(Color.accentColor.opacity(0.12))
        )
        .overlay(
            Capsule()
                .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
        .foregroundStyle(Color.accentColor)
    }

    private var statsRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "banknote")
                    .font(.title2)
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("Earned This Week")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if isPendingPayout, earnedThisWeek > 0 {
                            Text("⏳ Pending")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(CurrencyFormatter.string(earnedThisWeek))
                        .font(.title3.bold())
                        .monospacedDigit()
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("Quests")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(completedQuestCount)/\(totalQuestCount)")
                    .font(.title3.bold())
                    .monospacedDigit()
            }
        }
    }
}
