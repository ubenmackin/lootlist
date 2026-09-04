//
//  ChildHubCardsView.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import Charts
import SwiftUI

/// Today's chores and active FIFO goal. Extracted from ChildHubView to keep
/// the hub composed of ~80-line sections with no logic change.
struct ChildHubCardsView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let viewModel: ChildHubViewModel
    let cachedQuests: [QuestCache]
    let cachedCompletions: [QuestCompletionCache]
    let submittingQuestIDs: Set<String>
    let familyRecordName: String?
    let onCompleteQuest: (QuestCache) -> Void
    let onWithdraw: (QuestCache, QuestCompletionCache) -> Void

    /// Lightweight ledger slice for sparkline; optional to keep init compatible.
    let recentLedgers: [LedgerEntryCache]
    let streak: Int
    /// Family templates for day-checklist labels; optional so existing callers keep compiling.
    let cachedTemplates: [QuestTemplateCache]

    init(
        viewModel: ChildHubViewModel,
        cachedQuests: [QuestCache],
        cachedCompletions: [QuestCompletionCache],
        submittingQuestIDs: Set<String>,
        familyRecordName: String?,
        onCompleteQuest: @escaping (QuestCache) -> Void,
        onWithdraw: @escaping (QuestCache, QuestCompletionCache) -> Void,
        recentLedgers: [LedgerEntryCache] = [],
        streak: Int = 0,
        cachedTemplates: [QuestTemplateCache] = []
    ) {
        self.viewModel = viewModel
        self.cachedQuests = cachedQuests
        self.cachedCompletions = cachedCompletions
        self.submittingQuestIDs = submittingQuestIDs
        self.familyRecordName = familyRecordName
        self.onCompleteQuest = onCompleteQuest
        self.onWithdraw = onWithdraw
        self.recentLedgers = recentLedgers
        self.streak = streak
        self.cachedTemplates = cachedTemplates
    }

    private var templatesByID: [String: QuestTemplateCache] {
        Dictionary(uniqueKeysWithValues: cachedTemplates.map { ($0.recordName, $0) })
    }

    var body: some View {
        if horizontalSizeClass == .regular {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: DesignSystemConstants.Padding.standard) {
                    activeGoalCard
                }
                .frame(maxWidth: .infinity)
                VStack(spacing: DesignSystemConstants.Padding.standard) {
                    todaysChoresCard
                }
                .frame(maxWidth: .infinity)
                VStack(spacing: DesignSystemConstants.Padding.standard) {
                    streakSparklineCard
                }
                .frame(maxWidth: .infinity)
            }
        } else {
            VStack(spacing: DesignSystemConstants.Padding.standard) {
                todaysChoresCard
                activeGoalCard
                streakSparklineCard
            }
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
                                subtitle: row.subtitle,
                                amountText: "+\(CurrencyFormatter.string(row.amount))",
                                style: .pendingReview,
                                isSubmitting: isSubmitting,
                                onLeadingAction: { onWithdraw(quest, log) },
                                accessibilityID: "hub.choreRow-\(row.id)"
                            )
                        }
                        .buttonStyle(.plain)
                        .hoverEffect(.highlight)
                        .accessibilityHint("Awaiting parent verification. Tap to unsubmit.")
                    } else if let quest {
                        let questLogs = cachedCompletions.filter { $0.questRecordName == quest.recordName }
                        // WHY: specific-days renders as day checklist so each approval ticks one weekday.
                        if SpecificDaysHelper.isMultiPart(quest: quest, templatesByID: templatesByID) {
                            MultiPartQuestCard(
                                quest: quest,
                                logs: questLogs,
                                specificDays: SpecificDaysHelper.specificDays(for: quest, templatesByID: templatesByID),
                                subtitle: row.subtitle,
                                amountText: "+\(CurrencyFormatter.string(row.amount))",
                                isSubmitting: isSubmitting,
                                onCompleteSubPart: { _ in onCompleteQuest(quest) },
                                onWithdraw: { completionLog in onWithdraw(quest, completionLog) },
                                accessibilityID: "hub.choreRow-\(row.id)"
                            )
                        } else {
                            ChoreRowCard(
                                title: row.title,
                                subtitle: row.subtitle,
                                amountText: "+\(CurrencyFormatter.string(row.amount))",
                                style: .upcoming,
                                isSubmitting: isSubmitting,
                                isMultiPart: false,
                                onLeadingAction: { onCompleteQuest(quest) },
                                accessibilityID: "hub.choreRow-\(row.id)"
                            )
                            .hoverEffect(.highlight)
                        }
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
                let pacing = GoalPacingCalculator.calculatePacing(
                    targetAmountPennies: summary.goal.targetAmountPennies,
                    savedPennies: summary.savedPennies,
                    createdAt: summary.goal.createdAt,
                    targetDate: summary.goal.targetDate,
                    completedAt: summary.goal.completedAt
                )

                VStack(alignment: .leading, spacing: DesignSystemConstants.Padding.small) {
                    HStack(alignment: .top, spacing: DesignSystemConstants.Padding.small) {
                        Text(summary.goal.emojiIcon ?? "🎯").font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(summary.goal.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(2)
                            if let pacing, pacing.status != .noDeadline {
                                HStack(spacing: 3) {
                                    Image(systemName: pacing.status.iconSystemName)
                                        .font(.caption2)
                                    Text(pacing.status.badgeText)
                                        .font(.caption2.weight(.bold))
                                }
                                .foregroundStyle(pacing.status.tintColor)
                            }
                        }
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

    private var streakSparklineCard: some View {
        VStack(spacing: DesignSystemConstants.Padding.medium) {
            SectionHeader("Momentum")
            if recentLedgers.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.title3)
                        .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue).opacity(0.6))
                    Text("Complete quests & log savings to see your sparkline.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(height: 80)
                .frame(maxWidth: .infinity)
            } else {
                let points = sparklinePoints
                let yValues = points.map(\.amount)
                let minY = yValues.min() ?? 0
                let maxY = yValues.max() ?? 0
                let yDomain: ClosedRange<Double> = {
                    if minY == maxY {
                        return (minY - 1) ... (maxY + 1)
                    }
                    let padding = max(1.0, (maxY - minY) * 0.12)
                    return (minY - padding) ... (maxY + padding)
                }()
                Chart(points) { point in
                    LineMark(
                        x: .value("Day", point.label),
                        y: .value("Amount", point.amount)
                    )
                    .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))
                    .interpolationMethod(.catmullRom)
                    AreaMark(
                        x: .value("Day", point.label),
                        y: .value("Amount", point.amount)
                    )
                    .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen).opacity(0.15))
                    .interpolationMethod(.catmullRom)
                }
                .chartYScale(domain: yDomain)
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: .automatic) { _ in
                        AxisValueLabel()
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 80)
                .accessibilityLabel("Recent ledger sparkline")
            }
            HStack(spacing: 8) {
                DashboardStatBlock(icon: "flame.fill", value: "\(streak)", label: "Streak", tint: Color(DesignSystemConstants.Colors.pendingAmber))
                Divider()
                DashboardStatBlock(
                    icon: "banknote.fill",
                    value: CurrencyFormatter.string(viewModel.availableBalance),
                    label: "Balance",
                    tint: Color(DesignSystemConstants.Colors.primaryGreen)
                )
            }
        }
        .padding(DesignSystemConstants.Padding.standard)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .accessibilityIdentifier("hub.streakSparklineCard")
    }

    private var sparklinePoints: [WeeklyEarningPoint] {
        // WHY group by UTC dayKey so same-day ledgers sum into one point across timezones.
        let grouped = Dictionary(grouping: recentLedgers) { WeekMath.dayKey(for: $0.date) }
        return grouped.keys.sorted().suffix(7).compactMap { key in
            guard let entries = grouped[key] else { return nil }
            let bucketDate = WeekMath.date(fromDayKey: key) ?? entries.map(\.date).min() ?? Date()
            let total = entries.reduce(0) { $0 + $1.amount }
            let label = bucketDate.formatted(.dateTime.month(.abbreviated).day())
            return WeeklyEarningPoint(id: key, weekStart: bucketDate, label: label, amount: total)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
            .fill(Color(DesignSystemConstants.Colors.cardSurface))
    }
}
