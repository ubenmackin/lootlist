import SwiftUI

struct TrophyCardView: View {

    let achievement: Achievement

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

    @ViewBuilder
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

    @ViewBuilder
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
        var message = achievement.description
        if !isEarned {
            message += "\n\nNeed: \(requirementHint)"
        }
        return message
    }

    private var statusHint: String { requirementHint }

    private var requirementHint: String {
        switch achievement.requirementType {
        case AchievementRequirement.firstQuest:
            return "Slain your first quest"
        case AchievementRequirement.questCount10:
            return "\(achievement.requirementValue) quests slain"
        case AchievementRequirement.questCount50:
            return "\(achievement.requirementValue) quests slain"
        case AchievementRequirement.questCount100:
            return "\(achievement.requirementValue) quests slain"
        case AchievementRequirement.weekly100:
            return "100% of a week slain"
        case AchievementRequirement.streak7:
            return "\(achievement.requirementValue)-day combo streak"
        case AchievementRequirement.streak30:
            return "\(achievement.requirementValue)-day combo streak"
        case AchievementRequirement.gold100:
            return "$\(achievement.requirementValue) gold earned"
        case AchievementRequirement.gold500:
            return "$\(achievement.requirementValue) gold earned"
        case AchievementRequirement.ledgerCount10:
            return "\(achievement.requirementValue) ledger entries"
        case AchievementRequirement.ledgerWeeks4:
            return "\(achievement.requirementValue) weeks of spending"
        case AchievementRequirement.earlyBird9am:
            return "Slay a quest before 9 AM"
        default:
            return "Keep questing"
        }
    }
}

