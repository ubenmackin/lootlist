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
    @Query private var cachedTemplates: [QuestTemplateCache]
    @Query private var currentProfileRows: [ProfileCache]

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
        // profile predicate must stay in the Cache helper for isolation and I/O efficiency.
        // WHY stable sorts: CloudKit merge reorders can shuffle equal-dated rows; secondary recordName keeps ForEach(id: \.recordName) stable and avoids reorder churn across sync
        // passes.
        let completionFilter = QuestCompletionCache.completerPredicate(familyRecordName: targetFamily, completerRecordName: targetProfile)
        let ledgerFilter = LedgerEntryCache.profilePredicate(familyRecordName: targetFamily, profileRecordName: targetProfile)
        let questFilter = QuestCache.assignedPredicate(familyRecordName: targetFamily, assigneeRecordName: targetProfile)
        let allowanceFilter = AllowancePeriodCache.profilePredicate(familyRecordName: targetFamily, profileRecordName: targetProfile)
        let templateFilter = QuestTemplateCache.familyPredicate(familyRecordName: targetFamily)
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
        _cachedTemplates = Query(
            filter: templateFilter,
            sort: [SortDescriptor(\QuestTemplateCache.name), SortDescriptor(\QuestTemplateCache.recordName)]
        )
        // WHY: single-row scope keeps viewer identity cache-derived instead of session-derived.
        _currentProfileRows = Query(
            filter: HubQueryProvider.currentProfileFilter(family: targetFamily, profile: profileRecordName),
            sort: HubQueryProvider.currentProfileSort()
        )
    }

    /// Queried cache row for the active viewer; nil when scope has no synced row (fail-closed rendering).
    private var currentProfileRow: ProfileCache? {
        // WHY: resolver keeps empty-scope fail-closed while session identity bridges bootstrap before the param propagates.
        HubQueryProvider.resolveViewerRow(
            rows: currentProfileRows,
            profileRecordName: profileRecordName,
            fallbackRecordName: appState.currentProfile?.id.recordName
        )
    }

    var body: some View {
        NavigationStack {
            scrollBody
        }
        .navigationTitle("Money")
        .toolbar { ledgerToolbar }
        .navigationDestination(for: String.self, destination: spendingLogDestination)
        .sheet(isPresented: $isShowingLogSpending) {
            logSpendingSheetContent
        }
        .task {
            ensureViewModel()
            pushSyncSnapshot()
            checkPendingQuickAction(appState.pendingQuickAction)
            await lifecycleCoordinator?.performManualSync()
            pushSyncSnapshot()
        }
        .modifier(
            TreasuryCacheObservers(
                cachedCompletions: cachedCompletions,
                cachedLedgers: cachedLedgers,
                cachedQuests: cachedQuests,
                cachedAllowancePeriods: cachedAllowancePeriods,
                cachedTemplates: cachedTemplates,
                scope: scope,
                onCacheChanged: { rebuild() }
            )
        )
        .onChange(of: currentProfileRows) { _, _ in
            rebuild()
        }
        .onChange(of: appState.pendingQuickAction) { _, action in
            checkPendingQuickAction(action)
        }
        .onChange(of: viewModel?.errorMessage) { _, newError in
            if let newError, !newError.isEmpty {
                toastManager?.show(message: newError, type: .error)
            }
        }
        .onChange(of: syncHealth) { _, _ in
            pushSyncSnapshot()
        }
        .refreshable {
            await lifecycleCoordinator?.performManualSync()
            pushSyncSnapshot()
            rebuild()
        }
        // WHY: view identity tracks family+profile so @Query predicates (init-captured) are recreated on scope switch.
        .id("\(familyRecordName ?? "")-\(profileRecordName ?? "")")
    }

    private var scrollBody: some View {
        ScrollView {
            contentStack
        }
        .background(Color(DesignSystemConstants.Colors.background).ignoresSafeArea())
    }

    private var contentStack: some View {
        VStack(spacing: 20) {
            if let viewModel, viewModel.hasLoadedOnce {
                loadedContent(viewModel)
            } else {
                treasurySkeleton
            }
        }
        .padding(.vertical)
    }

    /// WHY redacted cards: skeleton holds layout so first sync populates without jump.
    private var treasurySkeleton: some View {
        VStack(spacing: 20) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(DesignSystemConstants.Colors.cardSurface))
                .frame(height: 148)
                .padding(.horizontal)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(DesignSystemConstants.Colors.cardSurface))
                .frame(height: 220)
                .padding(.horizontal)
            syncFootnote
                .padding(.horizontal)
        }
        .redacted(reason: .placeholder)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading your treasury")
        .accessibilityIdentifier("treasury.skeleton")
    }

    @ToolbarContentBuilder
    private var ledgerToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            NavigationLink(value: "spendingLog") {
                Label("Ledger", systemImage: "scroll.fill")
            }
        }
    }

    @ViewBuilder
    private func spendingLogDestination(for destination: String) -> some View {
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

    @ViewBuilder
    private var logSpendingSheetContent: some View {
        if let viewModel {
            LogSpendingView(
                viewModel: viewModel,
                familyRecordName: familyRecordName,
                profileRecordName: profileRecordName ?? currentProfileRows.first?.recordName
            )
        }
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
        // WHY: row-derived identity keeps rebuild cache-bound with fail-closed empty scope.
        guard currentProfileRow?.recordName != nil else { return }

        (vm ?? viewModel)?.rebuildLists(
            logs: cachedCompletions,
            ledgers: cachedLedgers,
            quests: cachedQuests,
            allowancePeriods: cachedAllowancePeriods,
            scope: scope,
            templates: cachedTemplates
        )
    }

    private var targetFamilyForStale: String {
        // WHY row-first family: the cache row owns scope with param fallback, session only bridges bootstrap.
        familyRecordName ?? currentProfileRow?.familyRecordName ?? appState.family?.id.recordName ?? ""
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
                isSyncing: syncHealth.isSyncing
            )
            .padding(.horizontal)
        }

        syncFootnote
            .padding(.horizontal)

        if cachedLedgers.isEmpty, cachedCompletions.isEmpty {
            // WHY fresh-gated empty: zero rows pre-hydration is still loading, post-hydration is genuinely empty.
            if isLedgerFresh {
                EmptyStateView(
                    systemImage: "banknote",
                    title: "No activity yet",
                    description: "Completed quests and spending will show up here.",
                    verticalPadding: 48
                )
                .padding(.horizontal)
            } else {
                treasurySkeleton
            }
            logSpendingButton
                .padding(.horizontal)
        } else {
            BalanceCardView(balance: viewModel.balance,
                            weekOf: viewModel.allowancePeriod?.weekOf ?? Date(),
                            status: viewModel.allowancePeriod?.status,
                            pendingPayoutAmount: viewModel.pendingQuestGold)
                .padding(.horizontal, 0)

            WeeklyBreakdownCard(breakdown: viewModel.weeklyBreakdown)

            logSpendingButton
                .padding(.horizontal)
        }
    }

    /// WHY struct-only: footnote and banner render this snapshot so the engine handle never enters the View.
    private var syncHealth: SyncHealthSnapshot {
        lifecycleCoordinator?.syncHealthSnapshot ?? SyncHealthSnapshot()
    }

    /// WHY prod-safe subset: inline footnote mirrors iCloudStatusView counts without DEBUG diagnostics.
    private var syncFootnote: some View {
        SyncFootnoteView(
            pendingCount: pendingCount,
            isSyncing: syncHealth.isSyncing,
            lastSyncedAt: viewModel?.lastSyncedAt ?? syncHealth.lastSyncedAt
        )
        .accessibilityIdentifier("treasury.syncFootnote")
    }

    /// WHY Bool snapshot: empty-versus-loading reads ViewModel-owned freshness so scope never crosses into the View.
    private var isLedgerFresh: Bool {
        CacheFreshness.isLedgerFresh(familyRecordName: targetFamilyForStale, appState: appState)
    }

    /// WHY single source: footnote reads the pushed snapshot with lifecycle fallback in one place.
    private var pendingCount: Int {
        // WHY lifecycle health: footnote counts ride the lifecycle layer so the engine handle never enters the View.
        viewModel?.pendingUploadCount ?? syncHealth.pendingUploadCount
    }

    private func pushSyncSnapshot() {
        // WHY lifecycle health: snapshot pushes ride the lifecycle layer so the engine handle never enters the View.
        viewModel?.applySyncSnapshot(
            pendingUploadCount: syncHealth.pendingUploadCount,
            lastSyncedAt: syncHealth.lastSyncedAt
        )
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

private struct TreasuryCacheObservers: ViewModifier {
    let cachedCompletions: [QuestCompletionCache]
    let cachedLedgers: [LedgerEntryCache]
    let cachedQuests: [QuestCache]
    let cachedAllowancePeriods: [AllowancePeriodCache]
    let cachedTemplates: [QuestTemplateCache]
    let scope: CalendarScope
    let onCacheChanged: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: cachedCompletions) { _, _ in onCacheChanged() }
            .onChange(of: cachedLedgers) { _, _ in onCacheChanged() }
            .onChange(of: cachedQuests) { _, _ in onCacheChanged() }
            .onChange(of: cachedAllowancePeriods) { _, _ in onCacheChanged() }
            .onChange(of: cachedTemplates) { _, _ in onCacheChanged() }
            .onChange(of: scope) { _, _ in onCacheChanged() }
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

    private func payoutRowValue(status: PayoutStatus, paidAmount: Int64?) -> String {
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
