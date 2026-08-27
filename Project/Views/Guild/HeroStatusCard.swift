//
//  HeroStatusCard.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import SwiftUI

struct HeroStatusCard: View {
    let summary: HeroSummary

    var recentQuestLogs: [QuestCompletion]?

    var onTap: (() -> Void)?

    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerRow
            questRatioBlock
            footerRow
            if let onTap {
                Button {
                    onTap()
                } label: {
                    recentLogsDisclosure
                }
                .buttonStyle(.plain)
            } else {
                recentLogsDisclosure
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.30), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            avatarView
            nameAndTitle
            Spacer(minLength: 8)
            StreakBadge(streak: summary.currentStreak, size: .small)
        }
    }

    private var avatarView: some View {
        let spec = summary.avatarRenderSpec ?? Self.fallbackSpec(for: summary.profile)
        return AvatarView(spec: spec, size: .small, showsNameAndTitle: false)
    }

    private var nameAndTitle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(summary.profile.displayName)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.80)
            if FeatureFlags.rpgImmersive {
                // RPG-era level title; hidden while the immersive layer is off.
                Text(XPService.title(forLevel: summary.profile.level))
                    .font(.caption)
                    .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))
            } else {
                Text(summary.profile.roleEnum?.displayName ?? summary.profile.role)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var questRatioBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Weekly Quests")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(summary.weeklyQuestsCompleted) / \(summary.weeklyQuestsTotal)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(ratioColor)
            }
            ProgressBar(
                value: Double(summary.weeklyQuestsCompleted),
                maximum: Double(max(summary.weeklyQuestsTotal, 1)),
                label: nil,
                tint: ratioColor,
                height: 8
            )
        }
    }

    private var ratioColor: Color {
        summary.weeklyQuestsTotal > 0
            && summary.weeklyQuestsCompleted >= summary.weeklyQuestsTotal
            ? Color(DesignSystemConstants.Colors.pendingAmber)
            : Color(DesignSystemConstants.Colors.primaryGreen)
    }

    private var footerRow: some View {
        HStack(spacing: 10) {
            MoneyBadge(amount: summary.weeklyGoldEarned, size: .small)
            Spacer()
            trophyChip
        }
    }

    private var trophyChip: some View {
        HStack(spacing: 4) {
            Image(systemName: "trophy.fill")
                .font(.caption2.weight(.bold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))
            Text("\(summary.trophiesEarned)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.16))
        )
        .overlay(
            Capsule().strokeBorder(Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.45), lineWidth: 1)
        )
        .accessibilityLabel("\(summary.trophiesEarned) trophies earned")
    }

    @ViewBuilder
    private var recentLogsDisclosure: some View {
        if let logs = recentQuestLogs {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    if logs.isEmpty {
                        Text("No recent completions")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(logs.prefix(5)) { log in
                            recentLogRow(log)
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                Label(logs.isEmpty ? "No Recent Completions" : "Recent Completions",
                      systemImage: "list.bullet.clipboard")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
    }

    private func recentLogRow(_ log: QuestCompletion) -> some View {
        HStack(spacing: 8) {
            Image(systemName: log.verificationStatus.iconSystemName)
                .foregroundStyle(log.verificationStatus.tintColor)
                .font(.caption)
            Text(log.completedDate, format: .dateTime.month().day().hour().minute())
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer()
            Text(log.verificationStatus.displayLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(log.verificationStatus.tintColor)
        }
        .padding(.vertical, 2)
    }

    private var accessibilityLabel: String {
        let name = summary.profile.displayName
        let ratio = "\(summary.weeklyQuestsCompleted) of \(summary.weeklyQuestsTotal) quests completed"
        let earned = CurrencyFormatter.string(summary.weeklyGoldEarned)
        let streak = "Streak \(summary.currentStreak) days"
        let trophies = "\(summary.trophiesEarned) trophies"
        return [name, ratio, earned, streak, trophies].joined(separator: ", ")
    }

    private static func fallbackSpec(for profileCache: ProfileCache) -> AvatarRenderSpec {
        // WHY: Views must not hold CloudKit types — derive AvatarRenderSpec from cache directly instead of converting via CKRecordZone.
        let preset: AvatarPreset? = if let id = profileCache.avatarName {
            AvatarPreset(rawValue: id) ?? AvatarPreset.resolve(profileCache.avatarClassEnum, id: id)
        } else if let cls = profileCache.avatarClassEnum {
            AvatarPreset.presets(for: cls).first
        } else {
            nil
        }
        return AvatarRenderSpec(
            preset: preset,
            customAvatarImageData: profileCache.customAvatarImageData,
            avatarEmoji: profileCache.avatarEmoji,
            displayName: profileCache.displayName,
            levelTitle: FeatureFlags.rpgImmersive ? XPService.title(forLevel: profileCache.level) : "",
            equippedAccessory: nil,
            avatarClass: profileCache.avatarClassEnum,
            role: profileCache.roleEnum ?? .hero
        )
    }
}
