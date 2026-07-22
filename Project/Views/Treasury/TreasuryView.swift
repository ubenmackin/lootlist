import SwiftUI
import CloudKit

struct TreasuryView: View {

    @Environment(AppState.self) private var appState
    @Environment(TreasuryService.self) private var treasury

    private let spending: any SpendingService

    @State private var viewModel: TreasuryViewModel?

    @State private var isShowingLogSpending: Bool = false

    init(spending: any SpendingService) {
        self.spending = spending
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let viewModel {
                        loadedContent(viewModel)
                    } else {
                        ProgressView("Summoning your treasury…")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                }
                .padding(.vertical)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Treasury")
            .navigationDestination(for: String.self) { destination in
                switch destination {
                case "spendingLog" where viewModel != nil:
                    if let viewModel {
                        SpendingLogView(viewModel: viewModel)
                    }
                default:
                    EmptyView()
                }
            }
            .sheet(isPresented: $isShowingLogSpending) {
                if let viewModel {
                    LogSpendingView(viewModel: viewModel)
                }
            }
            .task {
                if viewModel == nil {
                    viewModel = TreasuryViewModel(
                        treasury: treasury,
                        spending: spending,
                        appState: appState
                    )
                }
                await viewModel?.refresh()
            }
            .refreshable { await viewModel?.refresh() }
        }
    }

    @ViewBuilder
    private func loadedContent(_ viewModel: TreasuryViewModel) -> some View {
        BalanceCardView(balance: viewModel.balance,
                          weekOf: viewModel.allowancePeriod?.weekOf ?? Date(),
                          status: viewModel.allowancePeriod?.status)
            .padding(.horizontal, 0)

        WeeklyBreakdownCard(breakdown: viewModel.weeklyBreakdown)

        NavigationLink(value: "spendingLog") {
            HStack {
                Image(systemName: "scroll.fill")
                    .foregroundStyle(Color.gold)
                Text("Open Scroll of Spending")
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .font(.body.weight(.semibold))
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
        .padding(.horizontal)

        logSpendingButton
            .padding(.horizontal)

        if let error = viewModel.errorMessage, !error.isEmpty {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.red)
                .padding(.horizontal)
        }
    }

    private var logSpendingButton: some View {
        Button {
            isShowingLogSpending = true
        } label: {
            Label("Log Spending", systemImage: GoldFormat.coinSystemName)
                .font(.headline)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.gold)
                )
        }
        .disabled(viewModel?.canLogManually == false)
        .accessibilityHint("Add a new entry to your Scroll of Spending")
    }
}

struct WeeklyBreakdownCard: View {

    let breakdown: TreasuryService.WeeklyBreakdown?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("This Week's Loot")
                    .font(.headline)
                Spacer()
            }

            if let breakdown {
                BreakdownRow(label: "Quests Slain",
                              value: "\(breakdown.questsCount)",
                              icon: "checkmark.seal.fill",
                              tint: .green)
                BreakdownRow(label: "Gold from Quests",
                              value: GoldFormat.signed(breakdown.goldFromQuests),
                              icon: GoldFormat.coinSystemName,
                              tint: .gold)
                BreakdownRow(label: "Bonus Loot Drop",
                              value: GoldFormat.signed(breakdown.bonusGold),
                              icon: "gift.fill",
                              tint: .purple)
                BreakdownRow(label: "Spent",
                              value: GoldFormat.signed(breakdown.spent),
                              icon: "arrow.down.circle.fill",
                              tint: .red)
                Divider()
                BreakdownRow(label: "Net for the Week",
                              value: GoldFormat.signed(breakdown.net),
                              icon: "scalemass.fill",
                              tint: breakdown.net >= 0 ? .gold : .red,
                              isEmphasized: true)
            } else {
                HStack {
                    Spacer()
                    ProgressView()
                    Text("Tallying your loot…")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 8)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .padding(.horizontal)
    }
}

private struct BreakdownRow: View {

    let label: String
    let value: String
    let icon: String
    let tint: Color
    var isEmphasized: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 26)
            Text(label)
                .font(isEmphasized ? .subheadline.weight(.bold) : .subheadline)
                .foregroundStyle(isEmphasized ? .primary : .secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
        }
        .padding(.vertical, 2)
    }
}
