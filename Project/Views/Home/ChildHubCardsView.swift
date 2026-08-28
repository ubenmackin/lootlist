//
//  ChildHubCardsView.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import SwiftUI

/// Today's chores and active FIFO goal. Extracted from ChildHubView to keep
/// the hub composed of ~80-line sections with no logic change.
struct ChildHubCardsView: View {
    let viewModel: ChildHubViewModel
    let cachedQuests: [QuestCache]
    let cachedCompletions: [QuestCompletionCache]
    let submittingQuestIDs: Set<String>
    let familyRecordName: String?
    let onCompleteQuest: (QuestCache) -> Void
    let onWithdraw: (QuestCache, QuestCompletionCache) -> Void

    var body: some View {
        VStack(spacing: DesignSystemConstants.Padding.standard) {
            todaysChoresCard
            activeGoalCard
        }
    }

    private var todaysChoresCard: some View {
        VStack(spacing: DesignSystemConstants.Padding.medium) {
            SectionHeader("Today's Quests") {
                Text("\(viewModel.toDoCount) To Do")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if viewModel.choreRows.isEmpty {
                Text("No quests yet — enjoy the break!")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                ForEach(viewModel.choreRows) { row in
                    let quest = cachedQuests.first { $0.recordName == row.questRecordName }
                    let log = cachedCompletions.first { $0.recordName == row.completionRecordName }
                    let isSubmitting = submittingQuestIDs.contains(row.questRecordName)
                    if row.isPendingReview, let quest, let log {
                        Button { onWithdraw(quest, log) } label: {
                            ChoreRowCard(
                                title: row.title,
                                subtitle: "Sent to Parent for Review · Tap to Unsubmit",
                                amountText: "+\(CurrencyFormatter.string(row.amount))",
                                style: .pendingReview,
                                isSubmitting: isSubmitting,
                                onLeadingAction: { onWithdraw(quest, log) },
                                accessibilityID: "hub.choreRow-\(row.id)"
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Awaiting parent verification. Tap to unsubmit.")
                    } else if let quest {
                        ChoreRowCard(
                            title: row.title,
                            subtitle: row.subtitle,
                            amountText: "+\(CurrencyFormatter.string(row.amount))",
                            style: .upcoming,
                            isSubmitting: isSubmitting,
                            onLeadingAction: { onCompleteQuest(quest) },
                            accessibilityID: "hub.choreRow-\(row.id)"
                        )
                    }
                }
            }
        }
        .padding(DesignSystemConstants.Padding.standard)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var activeGoalCard: some View {
        VStack(spacing: DesignSystemConstants.Padding.medium) {
            SectionHeader("Active Goal") {
                NavigationLink { MyGoalsView(familyRecordName: familyRecordName) } label: {
                    Text("View All").font(.subheadline.weight(.semibold)).foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                }
                .accessibilityLabel("View all goals")
            }
            if let summary = viewModel.activeGoal {
                let savedDollars = Double(summary.savedPennies) / 100.0
                let targetDollars = Double(summary.goal.targetAmountPennies) / 100.0
                VStack(alignment: .leading, spacing: DesignSystemConstants.Padding.small) {
                    HStack(spacing: DesignSystemConstants.Padding.small) {
                        Text(summary.goal.emojiIcon ?? "🎯").font(.title3)
                        Text(summary.goal.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                        Spacer(minLength: DesignSystemConstants.Padding.small)
                        Text("\(CurrencyFormatter.string(savedDollars)) / \(CurrencyFormatter.string(targetDollars))").font(.caption.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    ProgressBar(value: savedDollars, maximum: targetDollars, label: nil, tint: Color(DesignSystemConstants.Colors.primaryGreen), height: 10)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Active goal \(summary.goal.name), \(CurrencyFormatter.string(savedDollars)) of \(CurrencyFormatter.string(targetDollars)) saved")
                .accessibilityIdentifier("hub.activeGoalCard")
            } else {
                Text("No active goal yet — tap View All to set one!")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }
        }
        .padding(DesignSystemConstants.Padding.standard)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
            .fill(Color(DesignSystemConstants.Colors.cardSurface))
    }
}
