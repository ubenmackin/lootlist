import CloudKit
import SwiftUI

struct PayoutHistoryView: View {
    @Environment(AppState.self) private var appState
    @Environment(QuestService.self) private var questService
    @Environment(TreasuryService.self) private var treasury
    @Environment(AchievementService.self) private var achievementService

    @State private var viewModel: FamilyDashboardViewModel?
    @State private var filter: PayoutFilter = .all
    @State private var selectedPeriod: AllowancePeriod?

    enum PayoutFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case paid = "Paid"
        var id: String {
            rawValue
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterPicker
                contentList
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Payout History")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if viewModel == nil {
                    viewModel = FamilyDashboardViewModel(
                        questService: questService,
                        treasury: treasury,
                        achievementService: achievementService,
                        appState: appState
                    )
                }

                await viewModel?.refresh()
                await viewModel?.loadPastPayouts(includeActive: true)
            }
            .refreshable {
                await viewModel?.loadPastPayouts(includeActive: true)
            }
            .sheet(item: $selectedPeriod) { period in
                PayoutDetailSheet(period: period, heroName: heroName(for: period))
            }
        }
    }

    private var filterPicker: some View {
        Picker("Filter", selection: $filter) {
            ForEach(PayoutFilter.allCases) { payoutFilter in
                Text(payoutFilter.rawValue).tag(payoutFilter)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private var contentList: some View {
        let payouts = filteredPayouts
        if payouts.isEmpty {
            emptyState
        } else {
            List {
                ForEach(payouts) { period in
                    Button {
                        selectedPeriod = period
                    } label: {
                        payoutRow(period)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color(.secondarySystemGroupedBackground))
                }
            }
            .listStyle(.insetGrouped)
            .background(Color(.systemGroupedBackground))
            .scrollContentBackground(.hidden)
        }
    }

    private var filteredPayouts: [AllowancePeriod] {
        guard let payouts = viewModel?.pastPayouts else { return [] }
        let sorted = payouts.sorted { $0.weekOf > $1.weekOf }
        switch filter {
        case .all: return sorted
        case .paid: return sorted.filter { $0.status == .paid }
        }
    }

    private func payoutRow(_ period: AllowancePeriod) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(period.weekOf, format: .dateTime.month().day().year())
                    .font(.subheadline.bold())
                    .monospacedDigit()
                Text(heroName(for: period))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(String(format: "%.2f gold", period.totalEarned))
                    .font(.subheadline.weight(.bold).monospacedDigit())

                statusBadge(for: period.status)
            }
        }
        .padding(.vertical, 4)
    }

    private func statusBadge(for status: PayoutStatus) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor(status))
                .frame(width: 6, height: 6)
            Text(status.displayName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(statusColor(status))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(statusColor(status).opacity(0.12))
        )
    }

    private func statusColor(_ status: PayoutStatus) -> Color {
        switch status {
        case .paid: .green
        case .payoutPending: .orange
        case .active: .blue
        }
    }

    private func heroName(for period: AllowancePeriod) -> String {
        let match = viewModel?.heroes.first { $0.id == period.profile.recordID }
        return match?.displayName ?? "Hero"
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No Payout History Yet")
                .font(.headline)
            Text("Payouts occur every Sunday when quests are tallied.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

private struct PayoutDetailSheet: View {
    let period: AllowancePeriod
    let heroName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Summary") {
                    LabeledContent("Hero", value: heroName)
                    LabeledContent("Week Of", value: period.weekOf.formatted(.dateTime.month().day().year()))
                    LabeledContent("Status", value: period.status.displayName)
                    LabeledContent("Quests Slain", value: "\(period.questsCompleted) of \(period.questsTotal)")
                    LabeledContent("Total Gold Earned", value: String(format: "%.2f", period.totalEarned))
                    if let paidDate = period.paidDate {
                        LabeledContent("Paid Date", value: paidDate.formatted(.dateTime.month().day().year()))
                    }
                }
            }
            .navigationTitle("Payout Detail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
