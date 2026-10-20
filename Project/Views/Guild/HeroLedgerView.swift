//
//  HeroLedgerView.swift
//  LootList
//
//  Created by Ben Mackin on 8/8/26.
//

import SwiftData
import SwiftUI

struct HeroLedgerView: View {
    let hero: ProfileCache
    let familyRecordName: String?
    private let profileRecordName: String?
    private let spending: SpendingService

    @Environment(AppState.self) private var appState
    @Environment(ToastManager.self) private var toastManager: ToastManager?

    @State private var viewModel: HeroLedgerViewModel?
    @State private var isShowingDeposit: Bool = false
    @State private var isShowingWithdraw: Bool = false
    @State private var isShowingTransfer: Bool = false

    @State private var showExportPicker = false
    @State private var showShareSheet = false
    @State private var shareURL: URL?
    @State private var selectedGroup: TransactionGroup?
    private let exportService = LedgerExportService()

    /// Persisted date-range scope for this hero's ledger screen.
    @AppStorage("heroLedger.calendarScope") private var scope: CalendarScope = .thisWeek

    @Query private var cachedLedgers: [LedgerEntryCache]
    @Query private var cachedQuests: [QuestCache]
    @Query private var cachedCompletions: [QuestCompletionCache]
    @Query private var cachedAllowancePeriods: [AllowancePeriodCache]
    @Query private var cachedTemplates: [QuestTemplateCache]
    @Query private var currentProfileRows: [ProfileCache]

    init(hero: ProfileCache, familyRecordName: String?, spending: SpendingService, profileRecordName: String? = nil) {
        self.hero = hero
        self.familyRecordName = familyRecordName
        self.profileRecordName = profileRecordName
        self.spending = spending
        let targetFamily = familyRecordName ?? ""
        let targetProfile = hero.recordName
        let ledgerFilter = LedgerEntryCache.profilePredicate(familyRecordName: targetFamily, profileRecordName: targetProfile)
        let questFilter = QuestCache.assignedPredicate(familyRecordName: targetFamily, assigneeRecordName: targetProfile)
        let completionFilter = QuestCompletionCache.completerPredicate(familyRecordName: targetFamily, completerRecordName: targetProfile)
        let allowancePeriodFilter = AllowancePeriodCache.profilePredicate(familyRecordName: targetFamily, profileRecordName: targetProfile)
        let templateFilter = QuestTemplateCache.familyPredicate(familyRecordName: targetFamily)

        // WHY stable sorts: secondary recordName keeps ForEach stable after CloudKit reorders.
        _cachedLedgers = Query(
            filter: ledgerFilter,
            sort: [SortDescriptor(\LedgerEntryCache.date, order: .reverse), SortDescriptor(\LedgerEntryCache.recordName)]
        )
        _cachedQuests = Query(
            filter: questFilter,
            sort: [SortDescriptor(\QuestCache.weekOf, order: .reverse), SortDescriptor(\QuestCache.recordName)]
        )
        _cachedCompletions = Query(
            filter: completionFilter,
            sort: [SortDescriptor(\QuestCompletionCache.completedDate, order: .reverse), SortDescriptor(\QuestCompletionCache.recordName)]
        )
        _cachedAllowancePeriods = Query(
            filter: allowancePeriodFilter,
            sort: [SortDescriptor(\AllowancePeriodCache.weekOf, order: .reverse), SortDescriptor(\AllowancePeriodCache.recordName)]
        )
        _cachedTemplates = Query(
            filter: templateFilter,
            sort: [SortDescriptor(\QuestTemplateCache.name), SortDescriptor(\QuestTemplateCache.recordName)]
        )
        // WHY: single-row scope keeps role and displayName cache-derived instead of session-derived.
        if let viewerProfile = profileRecordName.sanitizedNilIfEmpty {
            _currentProfileRows = Query(
                filter: ProfileCache.recordPredicate(recordName: viewerProfile, familyRecordName: targetFamily),
                sort: [SortDescriptor(\ProfileCache.displayName), SortDescriptor(\ProfileCache.recordName)]
            )
        } else {
            // WHY: family fallback keeps viewer gating live before the profile param propagates; row still resolves via session identity.
            _currentProfileRows = Query(
                filter: ProfileCache.familyPredicate(familyRecordName: targetFamily),
                sort: [SortDescriptor(\ProfileCache.displayName), SortDescriptor(\ProfileCache.recordName)]
            )
        }
    }

    /// Queried cache row for the active viewer; nil when scope has no synced row (fail-closed rendering).
    private var currentProfileRow: ProfileCache? {
        // WHY: resolver keeps empty-scope fail-closed while session identity bridges bootstrap before the param propagates.
        ProfileRowResolver.resolve(rows: currentProfileRows, targetRecordName: profileRecordName ?? appState.currentProfile?.id.recordName)
    }

    /// Viewer role derived from cache so gating never reads session domain state.
    private var viewerRole: UserRole? {
        currentProfileRow?.roleEnum
    }

    /// WHY distinct lets: one interpolation timed out type-checking, so build the identity from simple strings.
    private var viewIdentity: String {
        let family = familyRecordName ?? ""
        let subject = hero.recordName
        let viewer = profileRecordName ?? ""
        return family + "-" + subject + "-" + viewer
    }

    var body: some View {
        scrollBody
            .navigationTitle("Treasury")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ledgerToolbar }
            .modifier(sheetsModifier)
            .sheet(item: $selectedGroup) { group in
                LedgerGroupDetailSheet(group: group, selectedBucketFilter: viewModel?.selectedBucketFilter)
            }
            .modifier(lifecycleModifier)
            // WHY: view identity tracks family+subject+viewer so @Query predicates (init-captured) are recreated on scope switch.
            .id(viewIdentity)
    }

    private var sheetsModifier: some ViewModifier {
        SheetsModifier(
            isShowingDeposit: $isShowingDeposit,
            isShowingWithdraw: $isShowingWithdraw,
            isShowingTransfer: $isShowingTransfer,
            showExportPicker: $showExportPicker,
            showShareSheet: $showShareSheet,
            shareURL: shareURL,
            viewModel: viewModel,
            heroName: hero.displayName,
            familyRecordName: familyRecordName,
            heroRecordName: hero.recordName,
            onExport: { exportEntries(as: $0) }
        )
    }

    private var lifecycleModifier: some ViewModifier {
        LifecycleModifier(
            cachedLedgers: cachedLedgers,
            cachedQuests: cachedQuests,
            cachedCompletions: cachedCompletions,
            cachedAllowancePeriods: cachedAllowancePeriods,
            cachedTemplates: cachedTemplates,
            currentProfileRows: currentProfileRows,
            scope: scope,
            onAppear: { ensureViewModel() },
            onCacheChanged: { rebuild() }
        )
    }

    private var scrollBody: some View {
        ScrollView {
            contentStack
        }
        .background(Color(DesignSystemConstants.Colors.background))
    }

    private var contentStack: some View {
        VStack(spacing: 20) {
            LedgerStaleBanner(familyRecordName: familyRecordName, count: cachedLedgers.count)
                .padding(.horizontal)
            balanceSection
            scopeFilterSection
            actionsRow
            ledgerList
        }
        .padding(.vertical)
    }

    private var balanceSection: some View {
        LedgerBalanceHeaderView(
            totalBalance: viewModel?.balance,
            bucketBalances: viewModel?.bucketBalances ?? [:],
            selectedBucketFilter: viewModel?.selectedBucketFilter,
            pendingPayoutAmount: viewModel?.pendingQuestGold,
            onSelectTotal: { viewModel?.clearBucketFilter() },
            onSelectBucket: { viewModel?.toggleBucketFilter($0) }
        )
    }

    private var scopeFilterSection: some View {
        CalendarScopeFilterView(scope: $scope, payoutDay: payoutDay)
            .padding(.horizontal)
    }

    private var actionsRow: some View {
        HStack(spacing: 12) {
            depositButton
            withdrawButton
            moveMoneyButton
        }
        .padding(.horizontal)
    }

    private var payoutDay: PayoutDay {
        // WHY: subject hero override wins; viewer row keeps week math cache-derived with session fallback.
        hero.payoutDayEnum ?? currentProfileRow?.payoutDayEnum ?? appState.family?.payoutDay ?? .sunday
    }

    @ToolbarContentBuilder
    private var ledgerToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                showExportPicker = true
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            // WHY disabled for non-parents: ledger export is a privileged mutation surface.
            .disabled(viewerRole?.isParent != true)
        }
    }

    private func ensureViewModel() {
        ViewLifecycle.ensureAndRebuild(&viewModel, factory: {
            HeroLedgerViewModel(heroProfile: hero, spending: spending, appState: appState)
        }, rebuild: { vm in rebuild(vm) })
    }

    private func rebuild(_ vm: HeroLedgerViewModel? = nil) {
        (vm ?? viewModel)?.rebuildLedger(
            ledgers: cachedLedgers,
            quests: cachedQuests,
            completions: cachedCompletions,
            allowancePeriods: cachedAllowancePeriods,
            templates: cachedTemplates,
            scope: scope
        )
    }

    // MARK: - Export

    fileprivate enum ExportFormat { case csv, json }

    private func exportEntries(as format: ExportFormat) {
        // cachedLedgers is already profile-scoped via predicate pushdown.
        // WHY single source: goal markers reuse counted funds so history shows new money only.
        let filtered = cachedLedgers.filter { BucketService.isLedgerVisible($0) }
            .filter { scope.contains($0.date, payoutDay: payoutDay) }

        let data: Data
        switch format {
        case .csv:
            data = exportService.buildCSV(entries: filtered, childName: hero.displayName)
        case .json:
            do {
                data = try exportService.buildJSON(entries: filtered)
            } catch {
                toastManager?.show(message: "Could not build JSON export.", type: .error)
                return
            }
        }

        let ext = format == .csv ? "csv" : "json"
        let name = LedgerExportService.filename(child: hero.displayName, date: Date(), ext: ext)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: tempURL, options: .atomic)
            shareURL = tempURL
            showShareSheet = true
        } catch {
            toastManager?.show(message: "Could not write export file.", type: .error)
        }
    }

    private var depositButton: some View {
        Button {
            isShowingDeposit = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                Text("Deposit")
                    .font(.subheadline.weight(.bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(DesignSystemConstants.Colors.cardSurface))
            )
            .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(DesignSystemConstants.Colors.primaryGreen).opacity(0.4), lineWidth: 1)
            )
        }
    }

    private var withdrawButton: some View {
        Button {
            isShowingWithdraw = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "minus.circle.fill")
                Text("Withdraw")
                    .font(.subheadline.weight(.bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(DesignSystemConstants.Colors.cardSurface))
            )
            .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.4), lineWidth: 1)
            )
        }
    }

    private var moveMoneyButton: some View {
        Button {
            HapticsService.lightImpact()
            isShowingTransfer = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.left.arrow.right")
                Text("Move Money")
                    .font(.subheadline.weight(.bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(DesignSystemConstants.Colors.cardSurface))
            )
            .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(DesignSystemConstants.Colors.accentBlue).opacity(0.4), lineWidth: 1)
            )
        }
        .accessibilityIdentifier("ledger.moveMoneyButton")
        .accessibilityHint("Move money between buckets")
    }

    @ViewBuilder
    private var ledgerList: some View {
        if let vm = viewModel {
            if vm.filteredLedgerGroups.isEmpty {
                EmptyStateView(
                    systemImage: "banknote.fill",
                    title: LedgerEmptyState.title(for: vm.selectedBucketFilter, defaultTitle: "Empty Scroll"),
                    description: scope.emptyStateCopy,
                    topPadding: 32
                )
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(vm.filteredLedgerGroups) { group in
                        LedgerGroupRowView(
                            group: group,
                            selectedBucketFilter: vm.selectedBucketFilter,
                            onSelect: {
                                HapticsService.lightImpact()
                                selectedGroup = group
                            }
                        )
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

// MARK: - View Modifiers (extracted to keep body shallow for Swift 6 type-checker)

private extension HeroLedgerView {
    struct SheetsModifier: ViewModifier {
        @Binding var isShowingDeposit: Bool
        @Binding var isShowingWithdraw: Bool
        @Binding var isShowingTransfer: Bool
        @Binding var showExportPicker: Bool
        @Binding var showShareSheet: Bool
        let shareURL: URL?
        let viewModel: HeroLedgerViewModel?
        let heroName: String
        let familyRecordName: String?
        let heroRecordName: String
        let onExport: (ExportFormat) -> Void

        func body(content: Content) -> some View {
            content
                .sheet(isPresented: $isShowingDeposit) {
                    if let viewModel {
                        HeroTransactionView(mode: .deposit, viewModel: viewModel, heroName: heroName)
                    }
                }
                .sheet(isPresented: $isShowingWithdraw) {
                    if let viewModel {
                        HeroTransactionView(mode: .withdraw, viewModel: viewModel, heroName: heroName)
                    }
                }
                .sheet(isPresented: $isShowingTransfer) {
                    BucketTransferView(familyRecordName: familyRecordName, profileRecordName: heroRecordName)
                }
                .confirmationDialog("Export Ledger", isPresented: $showExportPicker) {
                    Button("Export as CSV") { onExport(.csv) }
                    Button("Export as JSON") { onExport(.json) }
                    Button("Cancel", role: .cancel) {}
                }
                .sheet(isPresented: $showShareSheet) {
                    if let shareURL {
                        ShareSheet(items: [shareURL])
                    }
                }
        }
    }

    /// WHY split ledger lifecycle into a typed modifier: deep modifier chains stall the Swift 6 type-checker.
    struct LifecycleModifier: ViewModifier {
        let cachedLedgers: [LedgerEntryCache]
        let cachedQuests: [QuestCache]
        let cachedCompletions: [QuestCompletionCache]
        let cachedAllowancePeriods: [AllowancePeriodCache]
        let cachedTemplates: [QuestTemplateCache]
        let currentProfileRows: [ProfileCache]
        let scope: CalendarScope
        let onAppear: () -> Void
        let onCacheChanged: () -> Void

        func body(content: Content) -> some View {
            applyRemaining(to: applyCore(to: content))
        }

        private func applyCore(to content: Content) -> some View {
            content
                .onAppear { onAppear() }
                .task { onAppear() }
                .onChange(of: cachedLedgers) { _, _ in onCacheChanged() }
                .onChange(of: cachedQuests) { _, _ in onCacheChanged() }
                .onChange(of: cachedCompletions) { _, _ in onCacheChanged() }
        }

        private func applyRemaining(to view: some View) -> some View {
            view
                .onChange(of: cachedAllowancePeriods) { _, _ in onCacheChanged() }
                .onChange(of: cachedTemplates) { _, _ in onCacheChanged() }
                .onChange(of: currentProfileRows) { _, _ in onCacheChanged() }
                .onChange(of: scope) { _, _ in onCacheChanged() }
        }
    }
}
