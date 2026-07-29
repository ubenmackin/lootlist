//
//  TreasuryView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import SwiftData
import SwiftUI

struct TreasuryView: View {
    @Environment(AppState.self) private var appState
    @Environment(TreasuryService.self) private var treasury

    private let spending: any SpendingService

    @State private var viewModel: TreasuryViewModel?

    @State private var isShowingLogSpending: Bool = false

    @Query private var cachedCompletions: [QuestCompletionCache]
    @Query private var cachedLedgers: [LedgerEntryCache]
    @Query private var cachedQuests: [QuestCache]
    @Query private var cachedAllowancePeriods: [AllowancePeriodCache]

    /// Family record name used to push the family filter down to SwiftData.
    /// When `nil` (no family loaded) the queries return zero rows, which is
    /// the correct behavior — there is no family to scope to.
    private let familyRecordName: String?

    init(spending: any SpendingService, familyRecordName: String? = nil) {
        self.spending = spending
        self.familyRecordName = familyRecordName

        // so we don't fetch every family's rows and post-filter in Swift.
        // Mirrors the L1 branch style in `CacheService.upsertX`: nil family
        // means "no filter", non-nil means "filter by family". We do NOT use
        // the banned `familyRecordName ?? ""` sentinel — that conflicts with
        let completionFilter: Predicate<QuestCompletionCache>? = familyRecordName.map { name in
            #Predicate { $0.familyRecordName == name }
        }
        let ledgerFilter: Predicate<LedgerEntryCache>? = familyRecordName.map { name in
            #Predicate { $0.familyRecordName == name }
        }
        let questFilter: Predicate<QuestCache>? = familyRecordName.map { name in
            #Predicate { $0.familyRecordName == name && $0.isActive == true }
        }
        let allowanceFilter: Predicate<AllowancePeriodCache>? = familyRecordName.map { name in
            #Predicate { $0.familyRecordName == name }
        }
        _cachedCompletions = Query(
            filter: completionFilter,
            sort: \QuestCompletionCache.completedDate,
            order: .reverse
        )
        _cachedLedgers = Query(
            filter: ledgerFilter,
            sort: \LedgerEntryCache.date,
            order: .reverse
        )
        _cachedQuests = Query(
            filter: questFilter,
            sort: \QuestCache.weekOf,
            order: .reverse
        )
        _cachedAllowancePeriods = Query(
            filter: allowanceFilter,
            sort: \AllowancePeriodCache.weekOf,
            order: .reverse
        )
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
                // cache snapshot. Subsequent mutations re-fire `.onChange`.
                rebuild()
            }
            .onChange(of: cachedCompletions) { _, _ in rebuild() }
            .onChange(of: cachedLedgers) { _, _ in rebuild() }
            .onChange(of: cachedQuests) { _, _ in rebuild() }
            .onChange(of: cachedAllowancePeriods) { _, _ in rebuild() }
            .refreshable {
                // Pull-to-refresh re-derives from the current cache snapshot.
                rebuild()
            }
        }
    }

    private func rebuild() {
        guard let profileName = appState.currentProfile?.id.recordName else { return }

        // The `@Query` declarations above already filter by
        // `familyRecordName` (and the active flag where appropriate) at the
        // SwiftData/SQLite layer. The per-hero filters below stay in Swift
        // because the viewed hero varies per viewer and can't be pushed into
        // a static `Query` predicate.
        let logs = cachedCompletions.filter { $0.completerRecordName == profileName }
        let ledgers = cachedLedgers.filter { $0.profileRecordName == profileName }
        let quests = cachedQuests.filter { $0.assigneeRecordName == profileName }
        let allowancePeriods = cachedAllowancePeriods.filter { $0.profileRecordName == profileName }

        viewModel?.rebuildLists(
            logs: logs,
            ledgers: ledgers,
            quests: quests,
            allowancePeriods: allowancePeriods,
            showAllTime: false
        )
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
                if let status = breakdown.payoutStatus {
                    Divider()
                    BreakdownRow(label: "Payout",
                                 value: payoutRowValue(status: status, paidAmount: breakdown.paidAmount),
                                 icon: status.iconSystemName,
                                 tint: status == .paid ? .green : .orange,
                                 isEmphasized: true)
                }
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

    private func payoutRowValue(status: PayoutStatus, paidAmount: Double?) -> String {
        if status == .paid, let paidAmount {
            return "\(status.displayName) · \(GoldFormat.magnitude(paidAmount))"
        }
        return status.displayName
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
