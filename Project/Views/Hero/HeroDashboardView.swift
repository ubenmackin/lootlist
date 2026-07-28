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

    @Query(filter: #Predicate<QuestCache> { $0.isActive == true }, sort: \QuestCache.weekOf, order: .reverse) private var cachedQuests: [QuestCache]
    @Query(sort: \QuestCompletionCache.completedDate, order: .reverse) private var cachedCompletions: [QuestCompletionCache]
    @Query(filter: #Predicate<QuestTemplateCache> { $0.isActive == true }) private var cachedTemplates: [QuestTemplateCache]

    @State private var viewModel: HeroDashboardViewModel?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    goldBalanceCard
                    streakBanner
                    weekStrip
                    weeklyQuestsBreakdown
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .scrollContentBackground(.hidden)
            .navigationTitle("Quests")
            .navigationBarTitleDisplayMode(.large)
            .refreshable {
                // Pull-to-refresh re-derives from the current cache snapshot.
                // Background CloudKit freshness is driven by `SyncEngine`.
                rebuildViewModel()
            }
            .task {
                if viewModel == nil {
                    viewModel = HeroDashboardViewModel(appState: appState)
                }
                // synchronous initial render from the current `@Query`
                // cache snapshot. Subsequent mutations re-fire `.onChange`.
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
        guard let familyName = appState.family?.id.recordName else { return }

        let quests = cachedQuests
            .filter { $0.familyRecordName == familyName && $0.assigneeRecordName == profileName && $0.isActive }

        let logs = cachedCompletions
            .filter { $0.familyRecordName == familyName && $0.completerRecordName == profileName }

        let templates = cachedTemplates
            .filter { $0.familyRecordName == familyName }

        vm.rebuildLists(quests: quests, logs: logs, templates: templates)
    }

    private var goldBalanceCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "dollarsign.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Gold This Week")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(viewModel.map { String(format: "%.2f", $0.earnedThisWeek) } ?? "0.00")
                    .font(.title.bold())
                    .monospacedDigit()
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("Quests")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(viewModel?.completedQuests.count ?? 0)/\(viewModel?.weekQuests.count ?? 0)")
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

    private var weekStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(viewModel?.selectedDayCode != nil ? "Filter: \(selectedDayTitle)" : "Full Week Overview")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                if viewModel?.selectedDayCode != nil {
                    Button("Show Full Week") {
                        viewModel?.selectedDayCode = nil
                    }
                    .font(.caption.bold())
                }
            }

            if let vm = viewModel {
                HStack(spacing: 6) {
                    ForEach(vm.weekDays) { day in
                        let isSelected = vm.selectedDayCode == day.weekdayCode
                        let hasQuests = vm.hasQuests(on: day)
                        let isCompleted = vm.isDayCompleted(day: day)

                        Button {
                            if isSelected {
                                vm.selectedDayCode = nil
                            } else {
                                vm.selectedDayCode = day.weekdayCode
                            }
                        } label: {
                            VStack(spacing: 4) {
                                Text(day.shortName)
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(isSelected ? Color.white : (day.isToday ? Color.accentColor : .secondary))

                                Text("\(day.dayNumber)")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(isSelected ? Color.white : (day.isToday ? Color.accentColor : Color.primary))

                                if hasQuests {
                                    Circle()
                                        .fill(isCompleted ? Color.gray.opacity(0.5) : Color.green)
                                        .frame(width: 4, height: 4)
                                } else {
                                    Spacer().frame(height: 4)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(isSelected ? Color.accentColor : Color(.secondarySystemGroupedBackground))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(day.isToday && !isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var selectedDayTitle: String {
        guard let code = viewModel?.selectedDayCode,
              let day = viewModel?.weekDays.first(where: { $0.weekdayCode == code })
        else {
            return "Selected Day"
        }
        return "\(day.shortName) (\(day.dayNumber))"
    }

    @ViewBuilder
    private var weeklyQuestsBreakdown: some View {
        if let vm = viewModel {
            if let selectedDay = vm.selectedDayCode {
                let dayQuests = vm.questsForSelectedDay()
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(selectedDay.capitalized)'s Scheduled Quests")
                            .font(.headline)
                        if dayQuests.isEmpty {
                            emptyState(text: "No scheduled quests for \(selectedDay.capitalized)")
                        } else {
                            ForEach(dayQuests) { quest in
                                let zoneID = questService.cloudKitReference.resolvedZoneID
                                let logCache = vm.logsByQuestRecordName[quest.recordName]
                                NavigationLink {
                                    QuestDetailView(quest: quest.toQuest(zoneID: zoneID), initialLog: logCache?.toQuestCompletion(zoneID: zoneID))
                                } label: {
                                    QuestCardView(quest: quest)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if !vm.weeklyFlexibleQuests.isEmpty {
                        questSection(title: "Weekly Quests (Do Anytime) 🎯", quests: vm.weeklyFlexibleQuests)
                    }
                }
            } else {
                if vm.weekQuests.isEmpty {
                    emptyState(text: "No quests assigned for this week")
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        if !vm.todaysQuests.isEmpty {
                            questSection(title: "Today's Quests ⚔️", quests: vm.todaysQuests)
                        }

                        if !vm.weeklyFlexibleQuests.isEmpty {
                            questSection(title: "Weekly Quests (Do Anytime) 🎯", quests: vm.weeklyFlexibleQuests)
                        }

                        if !vm.upcomingQuests.isEmpty {
                            questSection(title: "Coming Up 📅", quests: vm.upcomingQuests)
                        }

                        if !vm.completedQuests.isEmpty {
                            questSection(title: "Completed 🟢", quests: vm.completedQuests)
                        }

                        if !vm.missedQuests.isEmpty {
                            questSection(title: "Missed ❌", quests: vm.missedQuests)
                        }
                    }
                }
            }
        }
    }

    private func questSection(title: String, quests: [QuestCache]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            ForEach(quests) { quest in
                let zoneID = questService.cloudKitReference.resolvedZoneID
                let logCache = viewModel?.logsByQuestRecordName[quest.recordName]
                NavigationLink {
                    QuestDetailView(quest: quest.toQuest(zoneID: zoneID), initialLog: logCache?.toQuestCompletion(zoneID: zoneID))
                } label: {
                    QuestCardView(quest: quest)
                }
                .buttonStyle(.plain)
            }
        }
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
