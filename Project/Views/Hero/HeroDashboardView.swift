//
//  HeroDashboardView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import SwiftData
import SwiftUI

struct HeroDashboardView: View {
    @Environment(AppState.self) private var appState
    @Environment(QuestService.self) private var questService

    @Query private var cachedQuests: [QuestCache]
    @Query private var cachedCompletions: [QuestCompletionCache]
    @Query private var cachedTemplates: [QuestTemplateCache]

    @State private var viewModel: HeroDashboardViewModel?
    @State private var submittingQuestIDs: Set<String> = []

    /// Family record name used to push the family filter down to SwiftData.
    /// When `nil` (no family loaded) the queries return zero rows, which is
    /// the correct behavior — there is no family to scope to.
    private let familyRecordName: String?

    init(familyRecordName: String? = nil) {
        self.familyRecordName = familyRecordName

        // Filter queries by family at the SwiftData store layer. When familyRecordName is nil,
        // scope to an empty string ("") so zero rows are returned rather than fetching unscoped across all families.
        let targetFamily = familyRecordName ?? ""
        let questFilter = #Predicate<QuestCache> { $0.familyRecordName == targetFamily && $0.isActive == true }
        let completionFilter = #Predicate<QuestCompletionCache> { $0.familyRecordName == targetFamily }
        let templateFilter = #Predicate<QuestTemplateCache> { $0.familyRecordName == targetFamily && $0.isActive == true }

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
        _cachedTemplates = Query(
            filter: templateFilter
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    goldBalanceCard
                    streakBanner
                    questBoard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .scrollContentBackground(.hidden)
            .navigationTitle("Quests")
            .navigationBarTitleDisplayMode(.large)
            .refreshable {
                rebuildViewModel()
            }
            .task {
                if viewModel == nil {
                    viewModel = HeroDashboardViewModel(appState: appState)
                }
                rebuildViewModel()
            }
            .onChange(of: cachedQuests) { _, _ in
                rebuildViewModel()
            }
            .onChange(of: cachedCompletions) { _, _ in
                rebuildViewModel()
            }
            .onChange(of: cachedTemplates) { _, _ in
                rebuildViewModel()
            }
        }
    }

    private func rebuildViewModel() {
        guard let vm = viewModel else { return }
        guard let profileName = appState.currentProfile?.id.recordName else { return }

        // Filter family-scoped cached records for the active hero profile.
        let quests = cachedQuests
            .filter { $0.assigneeRecordName == profileName && $0.isActive }

        let logs = cachedCompletions
            .filter { $0.completerRecordName == profileName }

        let templates = cachedTemplates

        vm.rebuildLists(quests: quests, logs: logs, templates: templates)
    }

    private var goldBalanceCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "banknote")
                .font(.system(size: 36))
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Earned This Week")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(viewModel.map { CurrencyFormatter.string($0.earnedThisWeek) } ?? CurrencyFormatter.string(0))
                    .font(.title.bold())
                    .monospacedDigit()
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("Quests")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(viewModel?.completedQuestCount ?? 0)/\(viewModel?.weekQuests.count ?? 0)")
                    .font(.title3.bold())
                    .monospacedDigit()
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    @ViewBuilder
    private var streakBanner: some View {
        if let streak = viewModel?.streak, streak > 0 {
            HStack(spacing: 8) {
                Image(systemName: "flame.fill")
                    .foregroundStyle(.orange)
                Text("\(streak) Combo Streak")
                    .font(.headline.bold())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.orange.opacity(0.15))
            )
        }
    }

    // MARK: - Quest Board (Hybrid Option 3)

    @ViewBuilder
    private var questBoard: some View {
        if let vm = viewModel {
            if vm.weekQuests.isEmpty {
                emptyState(text: "No quests assigned for this week")
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    // 1. Overdue quests — top priority with amber warning
                    if !vm.overdueQuests.isEmpty {
                        overdueSection(quests: vm.overdueQuests, vm: vm)
                    }

                    // 2. Today's Daily Routines
                    if !vm.todaysQuests.isEmpty {
                        dailyRoutinesSection(quests: vm.todaysQuests, vm: vm)
                    }

                    // 3. Weekly Bounties (flexible anytime quests)
                    if !vm.weeklyFlexibleQuests.isEmpty {
                        weeklyBountiesSection(quests: vm.weeklyFlexibleQuests, vm: vm)
                    }

                    // 4. Collapsible Upcoming Agenda
                    if !vm.upcomingQuests.isEmpty {
                        upcomingSection(quests: vm.upcomingQuests, vm: vm)
                    }

                    // If nothing in any section but we do have quests, they're all completed
                    if vm.overdueQuests.isEmpty, vm.todaysQuests.isEmpty,
                       vm.weeklyFlexibleQuests.isEmpty, vm.upcomingQuests.isEmpty
                    {
                        allDoneBanner
                    }
                }
            }
        }
    }

    // MARK: - Overdue Section

    private func overdueSection(quests: [QuestCache], vm: HeroDashboardViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Overdue", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            ForEach(quests) { quest in
                questCard(quest: quest, vm: vm, isOverdue: true)
            }
        }
    }

    // MARK: - Daily Routines Section

    private func dailyRoutinesSection(quests: [QuestCache], vm: HeroDashboardViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Today's Quests ⚔️", systemImage: "sun.max.fill")
                .font(.headline)
            ForEach(quests) { quest in
                questCard(quest: quest, vm: vm)
            }
        }
    }

    // MARK: - Weekly Bounties Section

    private func weeklyBountiesSection(quests: [QuestCache], vm: HeroDashboardViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Weekly Bounties 🎯", systemImage: "target")
                .font(.headline)
            ForEach(quests) { quest in
                questCard(quest: quest, vm: vm)
            }
        }
    }

    // MARK: - Upcoming Section (Collapsible)

    @State private var isUpcomingExpanded: Bool = false

    private func upcomingSection(quests: [QuestCache], vm: HeroDashboardViewModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy) { isUpcomingExpanded.toggle() }
            } label: {
                HStack {
                    Label("Upcoming Later This Week", systemImage: "calendar.badge.clock")
                        .font(.headline)
                    Spacer()
                    Image(systemName: isUpcomingExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if isUpcomingExpanded {
                ForEach(quests) { quest in
                    questCard(quest: quest, vm: vm)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
    }

    // MARK: - Quest Card Builder

    private func questCard(quest: QuestCache, vm: HeroDashboardViewModel, isOverdue: Bool = false) -> some View {
        let zoneID = questService.cloudKitReference.resolvedZoneID
        let questLogs = vm.logs(for: quest)
        let logCache = vm.logsByQuestRecordName[quest.recordName]

        return NavigationLink {
            QuestDetailView(quest: quest.toQuest(zoneID: zoneID), initialLog: logCache?.toQuestCompletion(zoneID: zoneID))
        } label: {
            QuestCardView(
                quest: quest,
                logs: questLogs,
                isOverdue: isOverdue,
                onComplete: {
                    let qID = quest.recordName
                    guard !submittingQuestIDs.contains(qID) else { return }
                    submittingQuestIDs.insert(qID)
                    Task {
                        defer { submittingQuestIDs.remove(qID) }
                        guard let profile = appState.currentProfile else { return }
                        _ = try? await questService.markComplete(quest: quest.toQuest(zoneID: zoneID), by: profile)
                    }
                }
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - All Done Banner

    private var allDoneBanner: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("All Quests Complete! 🎉")
                .font(.title3.bold())
            Text("Great work, adventurer!")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private func emptyState(text: String = "No quests today") -> some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text(text)
                .font(.title3.bold())
            Text("Claim your loot!")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}
