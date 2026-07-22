import SwiftUI
import CloudKit

struct PayoutHistoryView: View {

    @Environment(AppState.self) private var appState
    @Environment(QuestService.self) private var questService
    @Environment(TreasuryService.self) private var treasury
    @Environment(AchievementService.self) private var achievementService

    @State private var viewModel: FamilyDashboardViewModel?
    @State private var filter: PayoutFilter = .all
    @State private var selectedPeriod: AllowancePeriod?

    enum PayoutFilter: String, CaseIterable, Identifiable {
        case all  = "All"
        case paid = "Paid"
        var id: String { rawValue }
    }

    var body: some View {

        VStack(spacing: 0) {
            filterPicker
            contentList
        }
        .navigationTitle("Payout History")
        .navigationBarTitleDisplayMode(.large)
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

    private var filterPicker: some View {
        Picker("Filter", selection: $filter) {
            ForEach(PayoutFilter.allCases) { f in
                Text(f.rawValue).tag(f)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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
        case .all:  return sorted
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
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                GoldBadge(amount: period.totalEarned, size: .small)
                questRatioLabel(period)
                statusPill(period.status)
            }
        }
        .padding(.vertical, 6)
    }

    private func questRatioLabel(_ period: AllowancePeriod) -> some View {
        Text("\(period.questsCompleted) / \(period.questsTotal) quests")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private func statusPill(_ status: PayoutStatus) -> some View {
        HStack(spacing: 3) {
            Image(systemName: status.iconSystemName)
                .font(.caption2.weight(.bold))
            Text(status.displayName)
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(pillTint(status)))
        .overlay(Capsule().strokeBorder(pillStroke(status), lineWidth: 1))
    }

    private func pillTint(_ status: PayoutStatus) -> Color {
        switch status {
        case .active:        return Color.blue.opacity(0.16)
        case .payoutPending: return Color.orange.opacity(0.16)
        case .paid:          return Color.green.opacity(0.16)
        }
    }

    private func pillStroke(_ status: PayoutStatus) -> Color {
        switch status {
        case .active:        return Color.blue.opacity(0.50)
        case .payoutPending: return Color.orange.opacity(0.50)
        case .paid:          return Color.green.opacity(0.50)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("No payouts to show")
                .font(.headline)
            Text("Once a week ends on Loot Day, payouts will land here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
    }

    private func heroName(for period: AllowancePeriod) -> String {
        let recordID = period.profile.recordID
        if let hero = viewModel?.heroes.first(where: { $0.id == recordID }) {
            return hero.displayName
        }

        return "Hero"
    }
}

private struct PayoutDetailSheet: View {

    let period: AllowancePeriod
    let heroName: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Hero") {
                    Text(heroName)
                }
                Section("Week") {
                    LabeledRow(label: "Week of") {
                        Text(period.weekOf, format: .dateTime.month().day().year())
                            .monospacedDigit()
                    }
                    LabeledRow(label: "Status") {
                        statusText(period.status)
                    }
                }
                Section("Gold") {
                    LabeledRow(label: "Total Earned") {
                        GoldBadge(amount: period.totalEarned, size: .medium)
                    }
                    if let paid = period.paidAmount {
                        LabeledRow(label: "Paid Out") {
                            Text(String(format: "%.2f", paid))
                                .monospacedDigit()
                        }
                    }
                    if let paidDate = period.paidDate {
                        LabeledRow(label: "Paid On") {
                            Text(paidDate, format: .dateTime.month().day().year())
                                .monospacedDigit()
                        }
                    }
                }
                Section("Quests") {
                    LabeledRow(label: "Completed") {
                        Text("\(period.questsCompleted)")
                            .monospacedDigit()
                    }
                    LabeledRow(label: "Total Assigned") {
                        Text("\(period.questsTotal)")
                            .monospacedDigit()
                    }
                    LabeledRow(label: "Completion %") {
                        let ratio = period.questsTotal > 0
                            ? Double(period.questsCompleted) / Double(period.questsTotal)
                            : 0
                        Text(String(format: "%.0f%%", ratio * 100))
                            .monospacedDigit()
                    }
                }
            }
            .navigationTitle("Payout Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func statusText(_ status: PayoutStatus) -> some View {
        HStack(spacing: 4) {
            Image(systemName: status.iconSystemName)
            Text(status.displayName)
        }
        .foregroundStyle(statusColor(status))
    }

    private func statusColor(_ status: PayoutStatus) -> Color {
        switch status {
        case .active:        return .blue
        case .payoutPending: return .orange
        case .paid:          return .green
        }
    }

    private struct LabeledRow<Content: View>: View {
        let label: String
        @ViewBuilder let content: Content
        var body: some View {
            HStack {
                Text(label)
                Spacer()
                content
                    .foregroundStyle(.secondary)
            }
        }
    }
}
