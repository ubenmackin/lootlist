//
//  HeroHeaderCardView.swift
//  LootList
//
//  Created by Ben Mackin on 8/8/26.
//

import SwiftData
import SwiftUI

struct HeroHeaderCardView: View {
    let profileCache: ProfileCache?
    let familyName: String?
    let streak: Int
    let earnedThisWeek: Double
    let completedQuestCount: Int
    let totalQuestCount: Int
    var isPendingPayout: Bool = false
    var levelProgress: LevelProgress?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerRow
            Divider()
            statsRow
            // Legacy RPG chrome hidden when FeatureFlags.rpgImmersive is false.
            if FeatureFlags.rpgImmersive, levelProgress != nil {
                Divider()
                xpProgressBarSection
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(DesignSystemConstants.Colors.cardSurface))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.30), lineWidth: 1)
        )
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            avatarView

            VStack(alignment: .leading, spacing: 4) {
                Text(profileCache?.displayName ?? "Hero")
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Text(XPService.title(forLevel: profileCache?.level ?? 1))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))
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
        ProfileAvatarView(profileCache: profileCache)
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
                .fill(Color(DesignSystemConstants.Colors.accentBlue).opacity(0.12))
        )
        .overlay(
            Capsule()
                .strokeBorder(Color(DesignSystemConstants.Colors.accentBlue).opacity(0.35), lineWidth: 1)
        )
        .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
    }

    private var statsRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "banknote")
                    .font(.title2)
                    .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("Earned This Week")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if isPendingPayout, earnedThisWeek > 0 {
                            Text("⏳ Pending")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))
                        }
                    }
                    Text(CurrencyFormatter.string(earnedThisWeek))
                        .font(.title3.bold())
                        .monospacedDigit()
                }
            }

            Spacer()

            // Legacy RPG chrome hidden when FeatureFlags.rpgImmersive is false.
            if FeatureFlags.rpgImmersive {
                HStack(spacing: 6) {
                    Text("💎")
                        .font(.headline)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Gems")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(profileCache?.gemsTotal ?? 0)")
                            .font(.title3.bold())
                            .monospacedDigit()
                            .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))
                    }
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

    private var xpProgressBarSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                // Legacy RPG chrome hidden when FeatureFlags.rpgImmersive is false.
                if FeatureFlags.rpgImmersive {
                    Text("Lv. \(levelProgress?.currentLevel ?? profileCache?.level ?? 1)")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(Color(DesignSystemConstants.Colors.accentBlue))
                        )
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color(.tertiarySystemFill))

                        Capsule()
                            .fill(LinearGradient(
                                colors: [Color(DesignSystemConstants.Colors.accentBlue), Color(DesignSystemConstants.Colors.accentBlue)],
                                startPoint: .leading,
                                endPoint: .trailing
                            ))
                            .frame(width: max(0, geo.size.width * CGFloat(levelProgress?.progress ?? 0)))
                            .animation(.spring(response: 0.6, dampingFraction: 0.8), value: levelProgress?.progress)
                    }
                }
                .frame(height: 8)

                Text("\(levelProgress?.xpIntoCurrentLevel ?? 0) / \(levelProgress?.xpForNextLevel ?? 1) XP")
                    .font(.caption.bold())
                    .monospacedDigit()
            }

            Text(XPService.title(forLevel: levelProgress?.currentLevel ?? profileCache?.level ?? 1))
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}
