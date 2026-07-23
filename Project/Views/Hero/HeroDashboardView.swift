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
                    questsList
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .containerRelativeFrame([.vertical])
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

            .overlay {
                if let vm = viewModel, vm.isLoading, vm.todaysQuests.isEmpty {
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
                Text("Templates")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(viewModel?.availableTemplatesCount ?? 0)")
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

    private var questsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let quests = viewModel?.todaysQuests, !quests.isEmpty {
                Text("Today's Quests")
                    .font(.headline)
                ForEach(quests) { quest in
                    NavigationLink {
                        QuestDetailView(quest: quest)
                    } label: {
                        QuestCardView(quest: quest)
                    }
                    .buttonStyle(.plain)
                }
            } else if let vm = viewModel, !vm.isLoading {
                emptyState
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("No quests today")
                .font(.title3.bold())
            Text("Claim your loot!")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}
