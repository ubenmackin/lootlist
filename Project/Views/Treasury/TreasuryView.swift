//
//  TreasuryView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import SwiftData
import SwiftUI

struct TreasuryView: View {
    @Environment(AppState.self) private var appState
    @Environment(TreasuryService.self) private var treasury
    @Environment(ToastManager.self) private var toastManager: ToastManager?
    @Environment(AppLifecycleCoordinator.self) private var lifecycleCoordinator: AppLifecycleCoordinator?

    private let spending: SpendingService

    @State private var viewModel: TreasuryViewModel?

    @State private var isShowingLogSpending: Bool = false

    /// Persisted date-range scope shared by the treasury and its pushed
    /// Spending Log screen so both observe the same filter binding. Stored in
    /// `UserDefaults` via `@AppStorage` so the selection survives app relaunches.
    @AppStorage("treasury.calendarScope") private var scope: CalendarScope = .thisWeek

    @Query private var cachedCompletions: [QuestCompletionCache]
    @Query private var cachedLedgers: [LedgerEntryCache]
    @Query private var cachedQuests: [QuestCache]
    @Query private var cachedAllowancePeriods: [AllowancePeriodCache]

    /// Family record name used to push the family filter down to SwiftData.
    /// When `nil` (no family loaded) the queries return zero rows, which is
    /// the correct behavior — there is no family to scope to.
    private let familyRecordName: String?
    private let profileRecordName: String?

    init(spending: SpendingService, familyRecordName: String? = nil, profileRecordName: String? = nil) {
        self.spending = spending
        self.familyRecordName = familyRecordName
        self.profileRecordName = profileRecordName

        let targetFamily = familyRecordName ?? ""
        let targetProfile = profileRecordName ?? ""
        FamilyScopeValidator.validateOrFault(targetFamily: targetFamily, viewName: "TreasuryView")
        // REGRESSION GUARD: TreasuryView is the exemplar for predicate pushdown — all four
        // queries MUST remain family + profile scoped at the store layer
        // (`familyRecordName == targetFamily && <profileField> == targetProfile`). Do not
        // regress to family-only predicates with in-memory `filter { profile == name }`; the
        // profile predicate must stay in the #Predicate for isolation and I/O efficiency.
        // WHY stable sorts: CloudKit merge reorders can shuffle equal-dated rows; secondary recordName keeps ForEach(id: \.recordName) stable and avoids reorder churn across sync
        // passes.
        let completionFilter = #Predicate<QuestCompletionCache> { $0.familyRecordName == targetFamily && $0.completerRecordName == targetProfile }
        let ledgerFilter = #Predicate<LedgerEntryCache> { $0.familyRecordName == targetFamily && $0.profileRecordName == targetProfile }
        let questFilter = #Predicate<QuestCache> { $0.familyRecordName == targetFamily && $0.assigneeRecordName == targetProfile && $0.isActive == true }
        let allowanceFilter = #Predicate<AllowancePeriodCache> { $0.familyRecordName == targetFamily && $0.profileRecordName == targetProfile }
        _cachedCompletions = Query(
            filter: completionFilter,
            sort: [SortDescriptor(\QuestCompletionCache.completedDate, order: .reverse), SortDescriptor(\QuestCompletionCache.recordName)]
        )
        _cachedLedgers = Query(
            filter: ledgerFilter,
            sort: [SortDescriptor(\LedgerEntryCache.date, order: .reverse), SortDescriptor(\LedgerEntryCache.recordName)]
        )
        _cachedQuests = Query(
            filter: questFilter,
            sort: [SortDescriptor(\QuestCache.weekOf, order: .reverse), SortDescriptor(\QuestCache.recordName)]
        )
        _cachedAllowancePeriods = Query(
            filter: allowanceFilter,
            sort: [SortDescriptor(\AllowancePeriodCache.weekOf, order: .reverse), SortDescriptor(\AllowancePeriodCache.recordName)]
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
            .background(Color(DesignSystemConstants.Colors.background).ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink(value: "spendingLog") {
                        Label("Ledger", systemImage: "scroll.fill")
                    }
                }
            }
            .navigationTitle("Money")
            .navigationDestination(for: String.self) { destination in
                switch destination {
                case "spendingLog" where viewModel != nil:
                    if let viewModel {
                        SpendingLogView(
                            viewModel: viewModel,
                            familyRecordName: familyRecordName,
                            profileRecordName: profileRecordName,
                            scope: $scope
                        )
                    }
                default:
                    EmptyView()
                }
            }
            .sheet(isPresented: $isShowingLogSpending) {
                if let viewModel {
                    LogSpendingView(viewModel: viewModel, familyRecordName: familyRecordName)
                }
            }
            .task {
                ensureViewModel()
                checkPendingQuickAction(appState.pendingQuickAction)
                await lifecycleCoordinator?.performManualSync()
            }
            .onChange(of: appState.pendingQuickAction) { _, action in
                checkPendingQuickAction(action)
            }
            .onChange(of: viewModel?.errorMessage) { _, newError in
                if let newError, !newError.isEmpty {
                    toastManager?.show(message: newError, type: .error)
                }
            }
            .onChange(of: cachedCompletions) { _, _ in rebuild() }
            .onChange(of: cachedLedgers) { _, _ in rebuild() }
            .onChange(of: cachedQuests) { _, _ in rebuild() }
            .onChange(of: cachedAllowancePeriods) { _, _ in rebuild() }
            .onChange(of: scope) { _, _ in rebuild() }
            .refreshable {
                await lifecycleCoordinator?.performManualSync()
                rebuild()
            }
        }
        // WHY: view identity tracks profileRecordName so @Query predicates (init-captured) are recreated on profile switch.
        .id(profileRecordName)
    }

    private func ensureViewModel() {
        ViewLifecycle.ensureAndRebuild(&viewModel, factory: {
            TreasuryViewModel(
                treasury: treasury,
                spending: spending,
                appState: appState
            )
        }, rebuild: { vm in rebuild(vm) })
    }

    private func rebuild(_ vm: TreasuryViewModel? = nil) {
        guard appState.currentProfile?.id.recordName != nil else { return }

        // Cached arrays are already profile-scoped via predicate pushdown; ViewModel keeps
        // defensive filtering internally but no main-thread filtering is needed here.
        (vm ?? viewModel)?.rebuildLists(
            logs: cachedCompletions,
            ledgers: cachedLedgers,
            quests: cachedQuests,
            allowancePeriods: cachedAllowancePeriods,
            scope: scope
        )
    }

    private var targetFamilyForStale: String {
        familyRecordName ?? appState.family?.id.recordName ?? ""
    }

    private func checkPendingQuickAction(_ action: QuickActionType?) {
        guard let action else { return }
        if action == .addTransaction {
            isShowingLogSpending = true
            appState.pendingQuickAction = nil
        }
    }

    @ViewBuilder
    private func loadedContent(_ viewModel: TreasuryViewModel) -> some View {
        if !targetFamilyForStale.isEmpty {
            StaleDataBanner(
                family: targetFamilyForStale,
                type: .ledgerEntry,
                count: cachedLedgers.count + cachedCompletions.count,
                isSyncing: lifecycleCoordinator?.isSyncing == true
            )
            .padding(.horizontal)
        }

        BalanceCardView(balance: viewModel.balance,
                        weekOf: viewModel.allowancePeriod?.weekOf ?? Date(),
                        status: viewModel.allowancePeriod?.status,
                        pendingPayoutAmount: viewModel.pendingQuestGold)
            .padding(.horizontal, 0)

        WeeklyBreakdownCard(breakdown: viewModel.weeklyBreakdown)

        logSpendingButton
            .padding(.horizontal)
    }

    private var logSpendingButton: some View {
        Button {
            isShowingLogSpending = true
        } label: {
            Label("Log Spending", systemImage: "banknote")
                .font(.headline)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(DesignSystemConstants.Colors.gold))
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
                Text("This Week's Earnings")
                    .font(.headline)
                Spacer()
            }

            if let breakdown {
                BreakdownRow(label: "Quests Completed",
                             value: "\(breakdown.questsCount)",
                             icon: "checkmark.seal.fill",
                             tint: Color(DesignSystemConstants.Colors.primaryGreen))
                BreakdownRow(label: "Earned from Quests",
                             value: CurrencyFormatter.signed(breakdown.goldFromQuests),
                             icon: "banknote",
                             tint: Color(DesignSystemConstants.Colors.gold))
                BreakdownRow(label: "Extra Bonus",
                             value: CurrencyFormatter.signed(breakdown.bonusGold),
                             icon: "gift.fill",
                             tint: Color(DesignSystemConstants.Colors.accentBlue))
                BreakdownRow(label: "Spent",
                             value: CurrencyFormatter.signed(breakdown.spent),
                             icon: "arrow.down.circle.fill",
                             tint: Color(DesignSystemConstants.Colors.dangerRed))
                if let status = breakdown.payoutStatus {
                    Divider()
                    BreakdownRow(label: "Payout",
                                 value: payoutRowValue(status: status, paidAmount: breakdown.paidAmount),
                                 icon: status.iconSystemName,
                                 tint: status == .paid ? Color(DesignSystemConstants.Colors.primaryGreen) : Color(DesignSystemConstants.Colors.pendingAmber),
                                 isEmphasized: true)
                }
                Divider()
                BreakdownRow(label: "Net for the Week",
                             value: CurrencyFormatter.signed(breakdown.net),
                             icon: "scalemass.fill",
                             tint: breakdown.net >= 0 ? Color(DesignSystemConstants.Colors.gold) : Color(DesignSystemConstants.Colors.dangerRed),
                             isEmphasized: true)
            } else {
                HStack {
                    Spacer()
                    ProgressView()
                    Text("Tallying your earnings…")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 8)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(DesignSystemConstants.Colors.cardSurface))
        )
        .padding(.horizontal)
    }

    private func payoutRowValue(status: PayoutStatus, paidAmount: Double?) -> String {
        if status == .paid, let paidAmount {
            return "\(status.displayName) · \(CurrencyFormatter.magnitude(paidAmount))"
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
