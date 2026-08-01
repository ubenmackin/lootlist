//
//  TrophyCardView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import SwiftUI

struct TrophyCardView: View {
    let achievement: AchievementCache

    let isEarned: Bool

    @State private var showingDetail: Bool = false

    var body: some View {
        Button {
            showingDetail = true
        } label: {
            cardContent
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("TrophyCard.\(achievement.name)")
        .accessibilityLabel(achievement.name)
        .accessibilityHint(isEarned ? "Trophy earned" : "Trophy locked")
        .accessibilityAddTraits(isEarned ? [.isButton] : [])
        .alert(achievement.name, isPresented: $showingDetail) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(detailMessage)
        }
    }

    private var cardContent: some View {
        VStack(spacing: 12) {
            iconStack

            Text(achievement.name)
                .font(.subheadline.bold())
                .foregroundStyle(isEarned ? Color.primary : Color.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)

            Text(isEarned ? "Earned" : statusHint)
                .font(.caption)
                .foregroundStyle(isEarned ? Color.gold : Color.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(isEarned ? Color.gold.opacity(0.18) : Color.secondary.opacity(0.12))
                )
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(cardBorder, lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if !isEarned {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            } else {
                Image(systemName: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(Color.gold)
                    .padding(8)
            }
        }
        .saturation(isEarned ? 1.0 : 0.0)
        .opacity(isEarned ? 1.0 : 0.65)
    }

    private var iconStack: some View {
        ZStack {
            Circle()
                .fill(isEarned ? Color.gold.opacity(0.2) : Color.secondary.opacity(0.1))
                .frame(width: 56, height: 56)
            Image(systemName: achievement.iconSystemName)
                .font(.system(size: 26))
                .foregroundStyle(isEarned ? Color.gold : Color.secondary)
        }
    }

    private var cardFill: Color {
        isEarned
            ? Color(.tertiarySystemBackground)
            : Color(.secondarySystemBackground)
    }

    private var cardBorder: Color {
        isEarned
            ? Color.gold.opacity(0.5)
            : Color.secondary.opacity(0.2)
    }

    private var detailMessage: String {
        var message = achievement.achievementDescription
        if !isEarned {
            message += "\n\nNeed: \(requirementHint)"
        }
        return message
    }

    private var statusHint: String {
        requirementHint
    }

    private var requirementHint: String {
        guard let req = achievement.requirementTypeEnum else {
            return ""
        }
        switch req {
        case .firstQuest:
            return "Completed your first quest"
        case .questCount10, .questCount50, .questCount100:
            return "\(achievement.requirementValue) quests completed"
        case .weekly100:
            return "100% of a week completed"
        case .streak7, .streak30:
            return "\(achievement.requirementValue)-day combo streak"
        case .gold100, .gold500:
            return "$\(achievement.requirementValue) gold earned"
        case .ledgerCount10:
            return "\(achievement.requirementValue) ledger entries"
        case .ledgerWeeks4:
            return "\(achievement.requirementValue) weeks of spending"
        case .earlyBird9am:
            return "Complete a quest before 9 AM"
        }
    }
}
