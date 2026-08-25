//
//  ChildHubView.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import CloudKit
import SwiftData
import SwiftUI

/// Home tab for the child role: balance hero card with bucket tiles, weekly
/// progress ring, today's chores, the active FIFO goal, and a pinned
/// log-a-purchase CTA.
struct ChildHubView: View {
    @Environment(AppState.self) private var appState
    @Environment(TreasuryService.self) private var treasury

    private let spending: SpendingService
    private let familyRecordName: String?

    @Query private var cachedQuests: [QuestCache]
    @Query private var cachedCompletions: [QuestCompletionCache]
    @Query private var cachedTemplates: [QuestTemplateCache]
    @Query private var cachedGoals: [GoalCache]
    @Query private var cachedLedgers: [LedgerEntryCache]
    @Query private var cachedAllowancePeriods: [AllowancePeriodCache]

    @State private var viewModel: ChildHubViewModel?
    @State private var treasuryViewModel: TreasuryViewModel?
    @State private var isShowingLogSpending: Bool = false

    init(spending: SpendingService, familyRecordName: String? = nil) {
        self.spending = spending
        self.familyRecordName = familyRecordName

        // Filter queries by family at the SwiftData store layer. When familyRecordName is nil,
        // scope to an empty string ("") so zero rows are returned rather than fetching unscoped across all families.
        let targetFamily = familyRecordName ?? ""
        let questFilter = #Predicate<QuestCache> { $0.familyRecordName == targetFamily && $0.isActive == true }
        let completionFilter = #Predicate<QuestCompletionCache> { $0.familyRecordName == targetFamily }
        let templateFilter = #Predicate<QuestTemplateCache> { $0.familyRecordName == targetFamily && $0.isActive == true }
        let goalFilter = #Predicate<GoalCache> { $0.familyRecordName == targetFamily }
        let ledgerFilter = #Predicate<LedgerEntryCache> { $0.familyRecordName == targetFamily }
        let allowanceFilter = #Predicate<AllowancePeriodCache> { $0.familyRecordName == targetFamily }

        _cachedQuests = Query(filter: questFilter, sort: \QuestCache.weekOf, order: .reverse)
        _cachedCompletions = Query(
            filter: completionFilter,
            sort: \QuestCompletionCache.completedDate,
            order: .reverse
        )
        _cachedTemplates = Query(filter: templateFilter, sort: \QuestTemplateCache.name)
        _cachedGoals = Query(filter: goalFilter, sort: \GoalCache.createdAt)
        _cachedLedgers = Query(filter: ledgerFilter, sort: \LedgerEntryCache.date, order: .reverse)
        _cachedAllowancePeriods = Query(filter: allowanceFilter, sort: \AllowancePeriodCache.weekOf, order: .reverse)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DesignSystemConstants.Padding.standard) {
                    header

                    if let viewModel {
                        balanceHeroCard(viewModel)
                        weeklyProgressCard(viewModel)
                        todaysChoresCard(viewModel)
                        activeGoalCard(viewModel)
                    }
                }
                .padding(.horizontal, DesignSystemConstants.Padding.standard)
                .padding(.top, DesignSystemConstants.Padding.small)
                .padding(.bottom, DesignSystemConstants.Padding.large)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                logPurchaseBar
                    .padding(.horizontal, DesignSystemConstants.Padding.standard)
                    .padding(.vertical, DesignSystemConstants.Padding.small)
                    .background(Color(.systemGroupedBackground))
            }
            .sheet(isPresented: $isShowingLogSpending) {
                if let treasuryViewModel {
                    LogSpendingView(viewModel: treasuryViewModel, familyRecordName: familyRecordName)
                }
            }
            .task {
                if viewModel == nil {
                    viewModel = ChildHubViewModel(
                        appState: appState,
                        cacheService: AppDependencies.shared?.cacheService
                    )
                }
                if treasuryViewModel == nil {
                    treasuryViewModel = TreasuryViewModel(
                        treasury: treasury,
                        spending: spending,
                        appState: appState
                    )
                }
                rebuild()
            }
            .onChange(of: cachedQuests) { _, _ in rebuild() }
            .onChange(of: cachedCompletions) { _, _ in rebuild() }
            .onChange(of: cachedTemplates) { _, _ in rebuild() }
            .onChange(of: cachedGoals) { _, _ in rebuild() }
            .onChange(of: cachedLedgers) { _, _ in rebuild() }
            .onChange(of: cachedAllowancePeriods) { _, _ in rebuild() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DesignSystemConstants.Padding.medium) {
            Text(appState.currentProfile?.avatarEmoji ?? "🦸")
                .font(.title2)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.green.opacity(0.15)))
                .overlay(Circle().strokeBorder(Color.green.opacity(0.3), lineWidth: 1))

            VStack(alignment: .leading, spacing: 0) {
                Text("CHILD VIEW")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text("\(firstName)'s Hub")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

            Spacer()

            NavigationLink {
                QuestsView(familyRecordName: familyRecordName)
            } label: {
                bellIcon
            }
            .buttonStyle(.plain)
            .accessibilityLabel(bellAccessibilityLabel)

            NavigationLink {
                SettingsView()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color(.tertiarySystemFill)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
    }

    private var bellIcon: some View {
        Image(systemName: "bell")
            .font(.body.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 40, height: 40)
            .background(Circle().fill(Color(.tertiarySystemFill)))
            .overlay(alignment: .topTrailing) {
                if let count = viewModel?.pendingReviewCount, count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(Circle().fill(Color.red))
                        .offset(x: 4, y: -4)
                }
            }
    }

    private var bellAccessibilityLabel: String {
        guard let count = viewModel?.pendingReviewCount, count > 0 else {
            return "Chores"
        }
        return "Chores, \(count) sent for review"
    }

    private var firstName: String {
        let name = appState.currentProfile?.displayName ?? "Hero"
        return name.split(separator: " ").first.map(String.init) ?? name
    }

    // MARK: - Balance Hero Card

    private func balanceHeroCard(_ viewModel: ChildHubViewModel) -> some View {
        VStack(alignment: .leading, spacing: DesignSystemConstants.Padding.medium) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hey \(firstName)! 👋")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("AVAILABLE BALANCE")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.85))
                }

                Spacer()

                Text("3-Jar Split")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.2)))
            }

            Text(CurrencyFormatter.string(viewModel.availableBalance))
                .font(.system(size: 40, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)

            Divider()
                .overlay(Color.white.opacity(0.35))

            HStack(spacing: DesignSystemConstants.Padding.small) {
                BucketTileView(
                    emoji: "🛍️",
                    title: "SPEND",
                    amountText: CurrencyFormatter.string(viewModel.bucketBalance(.spend))
                )
                BucketTileView(
                    emoji: "🐷",
                    title: "SHORT SAVE",
                    amountText: CurrencyFormatter.string(viewModel.bucketBalance(.shortTermSave))
                )
                BucketTileView(
                    emoji: "🌳",
                    title: "LONG SAVE",
                    amountText: CurrencyFormatter.string(viewModel.bucketBalance(.longTermSave))
                )
            }
        }
        .padding(DesignSystemConstants.Padding.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.header, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.green, Color.green.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Available balance \(CurrencyFormatter.string(viewModel.availableBalance))")
    }

    // MARK: - Weekly Progress Card

    private func weeklyProgressCard(_ viewModel: ChildHubViewModel) -> some View {
        HStack(alignment: .center, spacing: DesignSystemConstants.Padding.standard) {
            VStack(alignment: .leading, spacing: 4) {
                Text("WEEKLY PROGRESS")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text("\(viewModel.weeklyCompleted) / \(viewModel.weeklyGoal) Completed")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)
                Text(viewModel.streakHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            ProgressRingView(progress: viewModel.weeklyProgress, tint: .blue)
                .frame(width: 72, height: 72)
        }
        .padding(DesignSystemConstants.Padding.standard)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    // MARK: - Today's Chores Card

    private func todaysChoresCard(_ viewModel: ChildHubViewModel) -> some View {
        VStack(spacing: DesignSystemConstants.Padding.medium) {
            SectionHeader("Today's Chores") {
                Text("\(viewModel.toDoCount) To Do")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if viewModel.choreRows.isEmpty {
                Text("No chores yet — enjoy the break!")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                ForEach(viewModel.choreRows) { row in
                    ChoreRowCard(
                        title: row.title,
                        subtitle: row.subtitle,
                        amountText: "+\(CurrencyFormatter.string(row.amount))",
                        style: row.isPendingReview ? .pendingReview : .upcoming
                    )
                }
            }
        }
        .padding(DesignSystemConstants.Padding.standard)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    // MARK: - Active Goal Card

    private func activeGoalCard(_ viewModel: ChildHubViewModel) -> some View {
        VStack(spacing: DesignSystemConstants.Padding.medium) {
            SectionHeader("Active Goal") {
                NavigationLink {
                    MyGoalsView(familyRecordName: familyRecordName)
                } label: {
                    Text("View All")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .accessibilityLabel("View all goals")
            }

            if let summary = viewModel.activeGoal {
                let savedDollars = Double(summary.savedPennies) / 100.0
                let targetDollars = Double(summary.goal.targetAmountPennies) / 100.0

                VStack(alignment: .leading, spacing: DesignSystemConstants.Padding.small) {
                    HStack(spacing: DesignSystemConstants.Padding.small) {
                        Text(summary.goal.emojiIcon ?? "🎯")
                            .font(.title3)
                        Text(summary.goal.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: DesignSystemConstants.Padding.small)
                        Text("\(CurrencyFormatter.string(savedDollars)) / \(CurrencyFormatter.string(targetDollars))")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    ProgressBar(
                        value: savedDollars,
                        maximum: targetDollars,
                        label: nil,
                        tint: .green,
                        height: 10
                    )
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Active goal \(summary.goal.name), \(CurrencyFormatter.string(savedDollars)) of \(CurrencyFormatter.string(targetDollars)) saved")
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
            .fill(Color(.secondarySystemGroupedBackground))
    }

    // MARK: - Log-a-Purchase CTA

    private var logPurchaseBar: some View {
        Button {
            HapticsService.lightImpact()
            isShowingLogSpending = true
        } label: {
            Label("Log a Purchase / Spend", systemImage: "cart.fill")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.button, style: .continuous)
                        .fill(Color(DesignSystemConstants.Colors.primaryGreen))
                )
        }
        .accessibilityHint("Opens the spending log form")
    }

    // MARK: - Rebuild

    private func rebuild() {
        appState.updateCurrentProfileFromCache()
        guard let profileName = appState.currentProfile?.id.recordName else { return }

        viewModel?.rebuild(
            quests: cachedQuests,
            logs: cachedCompletions,
            templates: cachedTemplates,
            goals: cachedGoals
        )

        // Keep the spending-sheet view model in sync so Log a Purchase opens
        // with live balances, matching the Money tab's data path.
        if let treasuryViewModel {
            treasuryViewModel.rebuildLists(
                logs: cachedCompletions.filter { $0.completerRecordName == profileName },
                ledgers: cachedLedgers.filter { $0.profileRecordName == profileName },
                quests: cachedQuests.filter { $0.assigneeRecordName == profileName },
                allowancePeriods: cachedAllowancePeriods.filter { $0.profileRecordName == profileName },
                scope: .thisWeek
            )
        }
    }
}
