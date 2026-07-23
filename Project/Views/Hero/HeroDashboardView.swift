import CloudKit
import SwiftUI

struct HeroDashboardView: View {
    @Environment(AppState.self) private var appState
    @Environment(QuestService.self) private var questService

    @State private var viewModel: HeroDashboardViewModel?
    @State private var showError = false

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
                await viewModel?.load()
            }
            .task {
                if viewModel == nil {
                    viewModel = HeroDashboardViewModel(
                        questService: questService,
                        appState: appState
                    )
                }
                await viewModel?.load()
            }
            .onAppear {
                Task {
                    await viewModel?.load()
                }
            }
            .overlay {
                if let vm = viewModel, vm.isLoading, vm.weekQuests.isEmpty {
                    ProgressView("Summoning your quests…")
                        .padding()
                }
            }
            .alert("Couldn't load quests", isPresented: $showError) {
                Button("Retry") {
                    showError = false
                    Task { await viewModel?.load() }
                }
            } message: {
                if let error = viewModel?.loadError {
                    Text(error)
                }
            }
            .onChange(of: viewModel?.loadError) { _, newValue in
                if newValue != nil {
                    showError = true
                }
            }
        }
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
                Text("Week Overview (Sun – Sat)")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                if viewModel?.selectedDayCode != nil {
                    Button("Show All Week") {
                        viewModel?.selectedDayCode = nil
                    }
                    .font(.caption.bold())
                }
            }

            if let vm = viewModel {
                HStack(spacing: 6) {
                    ForEach(vm.weekDays) { day in
                        let isSelected = vm.selectedDayCode == day.weekdayCode
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
                                    .foregroundStyle(day.isToday ? Color.accentColor : .secondary)

                                Text("\(day.dayNumber)")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(isSelected ? Color.white : (day.isToday ? Color.accentColor : Color.primary))

                                Circle()
                                    .fill(day.isToday ? Color.accentColor : (day.isPast ? Color.gray.opacity(0.4) : Color.green))
                                    .frame(width: 4, height: 4)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(isSelected ? Color.accentColor : Color(.secondarySystemGroupedBackground))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(day.isToday ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var weeklyQuestsBreakdown: some View {
        if let vm = viewModel {
            if let selectedDay = vm.selectedDayCode {
                let dayQuests = vm.questsForSelectedDay()
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(selectedDay.capitalized)'s Quests")
                        .font(.headline)
                    if dayQuests.isEmpty {
                        emptyState(text: "No quests for \(selectedDay.capitalized)")
                    } else {
                        ForEach(dayQuests) { quest in
                            NavigationLink {
                                QuestDetailView(quest: quest)
                            } label: {
                                QuestCardView(quest: quest)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else {
                if vm.weekQuests.isEmpty && !vm.isLoading {
                    emptyState(text: "No quests assigned for this week")
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        if !vm.todaysQuests.isEmpty {
                            questSection(title: "Today's Quests ⚔️", quests: vm.todaysQuests)
                        }

                        if !vm.upcomingQuests.isEmpty {
                            questSection(title: "Coming Up 📅", quests: vm.upcomingQuests)
                        }

                        if !vm.completedQuests.isEmpty {
                            questSection(title: "Done / Slain 🟢", quests: vm.completedQuests)
                        }

                        if !vm.missedQuests.isEmpty {
                            questSection(title: "Missed ❌", quests: vm.missedQuests)
                        }
                    }
                }
            }
        }
    }

    private func questSection(title: String, quests: [Quest]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            ForEach(quests) { quest in
                NavigationLink {
                    QuestDetailView(quest: quest)
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
