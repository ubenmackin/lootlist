//
//  ChildHubView.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import os
import SwiftData
import SwiftUI

/// Home tab for the child role: balance hero card with bucket tiles, weekly
/// progress ring, today's chores, the active FIFO goal, and a pinned
/// log-a-purchase CTA.
struct ChildHubView: View {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "ChildHubView")

    @Environment(AppState.self) private var appState
    @Environment(TreasuryService.self) private var treasury
    @Environment(QuestService.self) private var questService

    @Query private var cachedQuests: [QuestCache]
    @Query private var cachedCompletions: [QuestCompletionCache]
    @Query private var cachedTemplates: [QuestTemplateCache]
    @Query private var cachedGoals: [GoalCache]
    @Query private var cachedLedgers: [LedgerEntryCache]
    @Query private var cachedAllowancePeriods: [AllowancePeriodCache]
    @Query private var currentProfileRows: [ProfileCache]

    @State private var viewModel: ChildHubViewModel?
    @State private var treasuryViewModel: TreasuryViewModel?
    @State private var isShowingLogSpending: Bool = false
    @State private var isShowingSplit: Bool = false
    @State private var submittingQuestIDs: Set<String> = []
    @State private var showCelebration: Bool = false
    @State private var pendingWithdrawal: PendingWithdrawal?

    struct PendingWithdrawal: Identifiable {
        let quest: QuestCache
        let log: QuestCompletionCache
        var id: String {
            quest.recordName
        }
    }

    private let spending: SpendingService
    private let familyRecordName: String?

    private let profileRecordName: String?

    init(spending: SpendingService, familyRecordName: String? = nil, profileRecordName: String? = nil) {
        self.spending = spending
        self.familyRecordName = familyRecordName
        self.profileRecordName = profileRecordName

        // Scope queries to family at store layer; nil familyRecordName uses "" to return zero rows (no cross-family fetch).
        let targetFamily = familyRecordName ?? ""
        let targetProfile = profileRecordName ?? ""
        let questFilter = #Predicate<QuestCache> { $0.familyRecordName == targetFamily && $0.isActive == true }
        let completionFilter = #Predicate<QuestCompletionCache> { $0.familyRecordName == targetFamily }
        let templateFilter = #Predicate<QuestTemplateCache> { $0.familyRecordName == targetFamily && $0.isActive == true }
        let goalFilter = #Predicate<GoalCache> { $0.familyRecordName == targetFamily }
        let ledgerFilter = #Predicate<LedgerEntryCache> { $0.familyRecordName == targetFamily }
        let allowanceFilter = #Predicate<AllowancePeriodCache> { $0.familyRecordName == targetFamily }
        let currentProfileFilter = #Predicate<ProfileCache> {
            $0.recordName == targetProfile && $0.familyRecordName == targetFamily
        }

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
        _currentProfileRows = Query(
            filter: currentProfileFilter,
            sort: \ProfileCache.displayName
        )
    }

    /// Queried cache row for active hero profile; nil when scope has no synced row (fail-closed rendering).
    private var currentProfileRow: ProfileCache? {
        currentProfileRows.first
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
            .overlay {
                CelebrationOverlay(isPresented: showCelebration)
            }
            .alert(
                "Unsubmit Quest?",
                isPresented: Binding(
                    get: { pendingWithdrawal != nil },
                    set: {
                        if !$0 {
                            pendingWithdrawal = nil
                        }
                    }
                ),
                presenting: pendingWithdrawal
            ) { target in
                Button("Move Back to To-Do", role: .destructive) {
                    withdrawQuest(target.quest, log: target.log)
                }
                Button("Keep Sent for Review", role: .cancel) {
                    pendingWithdrawal = nil
                }
            } message: { target in
                Text("Move “\(target.quest.questName)” back to your active to-do list?")
            }
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
            .sheet(isPresented: $isShowingSplit) {
                SavingsSplitView(
                    familyRecordName: familyRecordName,
                    profileRecordName: profileRecordName ?? appState.currentProfile?.id.recordName
                )
            }
            .task { ensureViewModels() }
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
            Text(currentProfileRow?.avatarEmoji ?? "🦸")
                .font(.title2)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color(DesignSystemConstants.Colors.primaryGreen).opacity(0.15)))
                .overlay(Circle().strokeBorder(Color(DesignSystemConstants.Colors.primaryGreen).opacity(0.3), lineWidth: 1))

            Text("\(firstName)'s Hub")
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer()
        }
        // Header is sole navigational identity; pending-review affordance lives in chore rows + tab badge.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(firstName)'s Hub")
        .accessibilityIdentifier("hub.headerTitle")
    }

    private var firstName: String {
        let name = currentProfileRow?.displayName ?? "Hero"
        return name.split(separator: " ").first.map(String.init) ?? name
    }

    // MARK: - Balance Hero Card

    private func balanceHeroCard(_ viewModel: ChildHubViewModel) -> some View {
        VStack(alignment: .leading, spacing: DesignSystemConstants.Padding.medium) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    // Warm in-card welcome; header above is sole navigational identity.
                    Text("Hey \(firstName)! 👋")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("AVAILABLE BALANCE")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.85))
                }

                Spacer()

                Button {
                    HapticsService.lightImpact()
                    isShowingSplit = true
                } label: {
                    Text("3-Jar Split")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.2)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Configure 3-Jar Split")
                .accessibilityIdentifier("hub.splitPillButton")
            }

            Text(CurrencyFormatter.string(viewModel.availableBalance))
                .font(.system(size: 40, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)

            Divider()
                .overlay(Color.white.opacity(0.35))

            HStack(spacing: DesignSystemConstants.Padding.small) {
                BucketTileView(
                    emoji: nil,
                    title: "SPEND",
                    amountText: CurrencyFormatter.string(viewModel.bucketBalance(.spend)),
                    accessibilityID: "hub.bucketTile-spend"
                )
                BucketTileView(
                    emoji: nil,
                    title: "SHORT SAVE",
                    amountText: CurrencyFormatter.string(viewModel.bucketBalance(.shortTermSave)),
                    accessibilityID: "hub.bucketTile-shortSave"
                )
                BucketTileView(
                    emoji: nil,
                    title: "LONG SAVE",
                    amountText: CurrencyFormatter.string(viewModel.bucketBalance(.longTermSave)),
                    accessibilityID: "hub.bucketTile-longSave"
                )
            }
        }
        .padding(DesignSystemConstants.Padding.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.header, style: .continuous)
                .fill(
                    // Blue token gradient for AA white-text contrast in both modes (replaces lower-contrast green).
                    LinearGradient(
                        colors: [
                            Color(DesignSystemConstants.Colors.accentBlue),
                            Color(DesignSystemConstants.Colors.accentBlue).opacity(0.85)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Available balance \(CurrencyFormatter.string(viewModel.availableBalance))")
        .accessibilityIdentifier("hub.balanceCard")
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

            ProgressRingView(progress: viewModel.weeklyProgress, tint: Color(DesignSystemConstants.Colors.accentBlue), identifier: "hub.weeklyProgressRing")
                .frame(width: 72, height: 72)
        }
        .padding(DesignSystemConstants.Padding.standard)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    // MARK: - Today's Chores Card

    private func todaysChoresCard(_ viewModel: ChildHubViewModel) -> some View {
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
                        Button {
                            pendingWithdrawal = PendingWithdrawal(quest: quest, log: log)
                        } label: {
                            ChoreRowCard(
                                title: row.title,
                                subtitle: "Sent to Parent for Review · Tap to Unsubmit",
                                amountText: "+\(CurrencyFormatter.string(row.amount))",
                                style: .pendingReview,
                                isSubmitting: isSubmitting,
                                onLeadingAction: {
                                    pendingWithdrawal = PendingWithdrawal(quest: quest, log: log)
                                },
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
                            onLeadingAction: {
                                completeQuest(quest)
                            },
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
                        tint: Color(DesignSystemConstants.Colors.primaryGreen),
                        height: 10
                    )
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
        .accessibilityIdentifier("hub.logPurchaseButton")
    }

    // MARK: - Rebuild

    private func ensureViewModels() {
        ViewLifecycle.ensure(&viewModel, factory: {
            ChildHubViewModel(
                appState: appState,
                cacheService: AppDependencies.shared?.cacheService
            )
        })
        ViewLifecycle.ensure(&treasuryViewModel, factory: {
            TreasuryViewModel(
                treasury: treasury,
                spending: spending,
                appState: appState
            )
        })
        rebuild()
    }

    private func rebuild() {
        appState.updateCurrentProfileFromCache()
        guard let profileName = appState.currentProfile?.id.recordName else { return }

        viewModel?.rebuild(
            quests: cachedQuests,
            logs: cachedCompletions,
            templates: cachedTemplates,
            goals: cachedGoals
        )

        // Keep spending-sheet view model synced for live balances on Log a Purchase (mirrors Money tab).
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

    // MARK: - Quest Actions

    private func withdrawQuest(_ quest: QuestCache, log: QuestCompletionCache) {
        let qID = quest.recordName
        guard !submittingQuestIDs.contains(qID) else { return }
        submittingQuestIDs.insert(qID)

        Task {
            defer { submittingQuestIDs.remove(qID) }
            guard let profile = appState.currentProfile else { return }
            do {
                try await questService.withdrawCompletion(questLog: log, by: profile)
                HapticsService.lightImpact()
            } catch {
                Self.logger.error("Failed to unsubmit quest: \(error, privacy: .private)")
            }
        }
    }

    private func completeQuest(_ quest: QuestCache) {
        let qID = quest.recordName
        guard !submittingQuestIDs.contains(qID) else { return }
        submittingQuestIDs.insert(qID)

        Task {
            defer { submittingQuestIDs.remove(qID) }
            guard let profile = appState.currentProfile else { return }

            let zoneID = appState.resolvedFamilyZoneID()
            let domain = quest.toQuest(zoneID: zoneID)

            do {
                let completion = try await questService.markComplete(
                    quest: domain,
                    by: profile
                )
                if completion.verificationStatus == .autoApproved {
                    HapticsService.success()
                    showCelebration = true
                    Task {
                        try? await Task.sleep(for: .seconds(DesignSystemConstants.Celebration.confettiLifetime))
                        showCelebration = false
                    }
                }
            } catch {
                Self.logger.error("Failed to mark quest complete: \(error, privacy: .private)")
            }
        }
    }
}
