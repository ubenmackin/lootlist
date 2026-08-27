//
//  MyChoresView.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import os
import SwiftData
import SwiftUI

/// Child-centric assigned chores screen. Displays two sections: chores awaiting
/// parent review (amber) and upcoming active quests (gray with green amount pill).
/// Complete action wires through the existing QuestCompletion pipeline, with
/// celebration overlay and success haptic on auto-approve completions.
struct MyChoresView: View {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "MyChoresView")
    @Environment(AppState.self) private var appState
    @Environment(QuestService.self) private var questService
    @Environment(AppLifecycleCoordinator.self) private var lifecycleCoordinator: AppLifecycleCoordinator?

    @Query private var cachedQuests: [QuestCache]
    @Query private var cachedCompletions: [QuestCompletionCache]

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

    private let familyRecordName: String?

    init(familyRecordName: String? = nil) {
        self.familyRecordName = familyRecordName

        let targetFamily = familyRecordName ?? ""
        let questFilter = #Predicate<QuestCache> {
            $0.familyRecordName == targetFamily && $0.isActive == true
        }
        let completionFilter = #Predicate<QuestCompletionCache> {
            $0.familyRecordName == targetFamily
        }

        _cachedQuests = Query(
            filter: questFilter,
            sort: \QuestCache.weekOf,
            order: .reverse
        )
        _cachedCompletions = Query(
            filter: completionFilter,
            sort: \QuestCompletionCache.completedDate,
            order: .reverse
        )
    }

    /// Active quests assigned to the current hero profile.
    private var profileQuests: [QuestCache] {
        guard let name = appState.currentProfile?.id.recordName else { return [] }
        return cachedQuests.filter { $0.assigneeRecordName == name && $0.isActive }
    }

    /// Completions logged by the current hero, grouped by quest.
    private var profileLogs: [QuestCompletionCache] {
        guard let name = appState.currentProfile?.id.recordName else { return [] }
        return cachedCompletions.filter { $0.completerRecordName == name }
    }

    /// Quests that have been approved or completed by the hero.
    private var completedQuests: [(quest: QuestCache, log: QuestCompletionCache)] {
        var result: [(QuestCache, QuestCompletionCache)] = []
        for quest in profileQuests {
            let questLogs = profileLogs.filter { $0.questRecordName == quest.recordName }
            let approvedLogs = questLogs.filter(\.isApproved)
            if GoldCalculation.isFullyCompleted(quest: quest, approvedCount: approvedLogs.count),
               let latest = approvedLogs.sorted(by: { $0.completedDate > $1.completedDate }).first
            {
                result.append((quest, latest))
            }
        }
        return result
    }

    /// Quests whose latest completion is pending parent verification.
    private var pendingReviewQuests: [(quest: QuestCache, log: QuestCompletionCache)] {
        let completedQuestNames = Set(completedQuests.map(\.quest.recordName))
        var result: [(QuestCache, QuestCompletionCache)] = []
        for quest in profileQuests where !completedQuestNames.contains(quest.recordName) {
            // Find the latest pending completion for this quest.
            if let latestLog = profileLogs
                .filter({ $0.questRecordName == quest.recordName && $0.verificationStatusEnum == .pending })
                .sorted(by: { $0.completedDate > $1.completedDate })
                .first
            {
                result.append((quest, latestLog))
            }
        }
        return result
    }

    /// Quests that are active but have no pending review and are not completed
    /// (available for the hero to complete).
    private var upcomingQuests: [QuestCache] {
        let pendingQuestNames = Set(pendingReviewQuests.map(\.quest.recordName))
        let completedQuestNames = Set(completedQuests.map(\.quest.recordName))
        return profileQuests.filter { quest in
            !pendingQuestNames.contains(quest.recordName) && !completedQuestNames.contains(quest.recordName)
        }
    }

    /// Whether any content exists — used for empty-state rendering.
    private var isEmpty: Bool {
        pendingReviewQuests.isEmpty && upcomingQuests.isEmpty && completedQuests.isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DesignSystemConstants.Padding.standard) {
                    if isEmpty {
                        emptyState
                    } else {
                        if !pendingReviewQuests.isEmpty {
                            pendingSection
                        }

                        if !upcomingQuests.isEmpty {
                            upcomingSection
                        }

                        if !completedQuests.isEmpty {
                            completedSection
                        }
                    }
                }
                .padding(.horizontal, DesignSystemConstants.Padding.standard)
                .padding(.top, DesignSystemConstants.Padding.small)
                .padding(.bottom, DesignSystemConstants.Padding.large)
            }
            .overlay {
                // Confetti celebration for auto-approved completions.
                CelebrationOverlay(isPresented: showCelebration)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("My Quests")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        HeroBoardView(familyRecordName: familyRecordName)
                    } label: {
                        Label("Hero Board", systemImage: "square.grid.2x2.fill")
                    }
                    .accessibilityIdentifier("chores.heroBoardLink")
                }
            }
            .refreshable {
                await lifecycleCoordinator?.performManualSync()
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
        }
    }

    // MARK: - Pending Review Section

    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: DesignSystemConstants.Padding.small) {
            SectionHeader("Sent for Review")

            ForEach(pendingReviewQuests, id: \.quest.recordName) { pair in
                Button {
                    pendingWithdrawal = PendingWithdrawal(quest: pair.quest, log: pair.log)
                } label: {
                    ChoreRowCard(
                        title: pair.quest.questName,
                        subtitle: "Sent to Parent for Review · Tap to Unsubmit",
                        amountText: CurrencyFormatter.string(pair.quest.goldReward),
                        style: .pendingReview,
                        isSubmitting: submittingQuestIDs.contains(pair.quest.recordName),
                        onLeadingAction: {
                            pendingWithdrawal = PendingWithdrawal(quest: pair.quest, log: pair.log)
                        },
                        accessibilityID: "chores.pendingRow-\(pair.quest.recordName)"
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint("Awaiting parent verification. Tap to unsubmit.")
            }
        }
    }

    // MARK: - Upcoming Section

    private var upcomingSection: some View {
        VStack(alignment: .leading, spacing: DesignSystemConstants.Padding.small) {
            SectionHeader("Upcoming") {
                EmptyView()
            }

            ForEach(upcomingQuests) { quest in
                ChoreRowCard(
                    title: quest.questName,
                    subtitle: quest.descriptionText,
                    amountText: CurrencyFormatter.string(quest.goldReward),
                    style: .upcoming,
                    isSubmitting: submittingQuestIDs.contains(quest.recordName),
                    onLeadingAction: {
                        completeQuest(quest)
                    },
                    accessibilityID: "chores.upcomingRow-\(quest.recordName)"
                )
            }
        }
    }

    // MARK: - Completed Section

    private var completedSection: some View {
        VStack(alignment: .leading, spacing: DesignSystemConstants.Padding.small) {
            SectionHeader("Completed") {
                EmptyView()
            }

            ForEach(completedQuests, id: \.quest.recordName) { pair in
                ChoreRowCard(
                    title: pair.quest.questName,
                    subtitle: "Completed",
                    amountText: "+\(CurrencyFormatter.string(pair.quest.goldReward))",
                    style: .completed,
                    accessibilityID: "chores.completedRow-\(pair.quest.recordName)"
                )
                .accessibilityHint("Completed quest")
            }
        }
    }

    // MARK: - Actions

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
            guard let profile = appState.currentProfile
            else { return }

            let zoneID = appState.resolvedFamilyZoneID()
            let domain = quest.toQuest(zoneID: zoneID)

            do {
                let completion = try await questService.markComplete(
                    quest: domain,
                    by: profile
                )
                // Auto-approved completions trigger a celebration overlay.
                if completion.verificationStatus == .autoApproved {
                    HapticsService.success()
                    // The silent 50xp credit is handled inside
                    // applyReward / QuestService+Rewards pipeline.
                    showCelebration = true
                    // Auto-dismiss the celebration after a short delay.
                    Task {
                        try? await Task.sleep(for: .seconds(DesignSystemConstants.Celebration.confettiLifetime))
                        showCelebration = false
                    }
                }
            } catch {
                Self.logger.error("Failed to mark chore complete: \(error, privacy: .private)")
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))

            Text("All Caught Up! 🎉")
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)

            Text(
                "You don't have any chores right now. When a parent assigns you a new quest, it'll show up here."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, DesignSystemConstants.Padding.large)

            Spacer()
        }
        .padding(.top, 64)
        .frame(maxWidth: .infinity)
    }
}
