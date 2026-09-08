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
    private let spending: SpendingService

    @Environment(AppState.self) private var appState
    @Environment(ToastManager.self) private var toastManager: ToastManager?

    @State private var viewModel: HeroLedgerViewModel?
    @State private var isShowingDeposit: Bool = false
    @State private var isShowingWithdraw: Bool = false

    @State private var showExportPicker = false
    @State private var showShareSheet = false
    @State private var shareURL: URL?
    private let exportService = LedgerExportService()

    /// Persisted date-range scope for this hero's ledger screen.
    @AppStorage("heroLedger.calendarScope") private var scope: CalendarScope = .thisWeek

    @Query private var cachedLedgers: [LedgerEntryCache]
    @Query private var cachedQuests: [QuestCache]
    @Query private var cachedCompletions: [QuestCompletionCache]
    @Query private var cachedAllowancePeriods: [AllowancePeriodCache]
    @Query private var cachedTemplates: [QuestTemplateCache]

    init(hero: ProfileCache, familyRecordName: String?, spending: SpendingService) {
        self.hero = hero
        self.familyRecordName = familyRecordName
        self.spending = spending
        let targetFamily = familyRecordName ?? ""
        let targetProfile = hero.recordName
        let ledgerFilter = LedgerEntryCache.profilePredicate(familyRecordName: targetFamily, profileRecordName: targetProfile)
        let questFilter = QuestCache.assignedPredicate(familyRecordName: targetFamily, assigneeRecordName: targetProfile)
        let completionFilter = QuestCompletionCache.completerPredicate(familyRecordName: targetFamily, completerRecordName: targetProfile)
        let allowancePeriodFilter = AllowancePeriodCache.profilePredicate(familyRecordName: targetFamily, profileRecordName: targetProfile)
        let templateFilter = QuestTemplateCache.familyPredicate(familyRecordName: targetFamily)

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
        _cachedCompletions = Query(
            filter: completionFilter,
            sort: \QuestCompletionCache.completedDate,
            order: .reverse
        )
        _cachedAllowancePeriods = Query(
            filter: allowancePeriodFilter,
            sort: \AllowancePeriodCache.weekOf,
            order: .reverse
        )
        _cachedTemplates = Query(filter: templateFilter, sort: \QuestTemplateCache.name)
    }

    var body: some View {
        scrollBody
            .navigationTitle("Treasury")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { ensureViewModel() }
            .task { ensureViewModel() }
            .onChange(of: cachedLedgers) { _, _ in rebuild() }
            .onChange(of: cachedQuests) { _, _ in rebuild() }
            .onChange(of: cachedCompletions) { _, _ in rebuild() }
            .onChange(of: cachedAllowancePeriods) { _, _ in rebuild() }
            .onChange(of: cachedTemplates) { _, _ in rebuild() }
            .onChange(of: scope) { _, _ in rebuild() }
            .sheet(isPresented: $isShowingDeposit) {
                depositSheetContent
            }
            .sheet(isPresented: $isShowingWithdraw) {
                withdrawSheetContent
            }
            .toolbar { ledgerToolbar }
            .confirmationDialog("Export Ledger", isPresented: $showExportPicker) {
                exportDialogContent
            }
            .sheet(isPresented: $showShareSheet) {
                shareSheetContent
            }
    }

    private var scrollBody: some View {
        ScrollView {
            contentStack
        }
        .background(Color(DesignSystemConstants.Colors.background))
    }

    private var contentStack: some View {
        VStack(spacing: 20) {
            balanceSection
            scopeFilterSection
            actionsRow
            ledgerList
        }
        .padding(.vertical)
    }

    private var balanceSection: some View {
        BalanceCardView(
            balance: viewModel?.balance,
            weekOf: nil,
            status: nil,
            pendingPayoutAmount: viewModel?.pendingQuestGold
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
        }
        .padding(.horizontal)
    }

    private var payoutDay: PayoutDay {
        hero.payoutDayEnum ?? appState.family?.payoutDay ?? .sunday
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
            .disabled(appState.currentProfile?.role.isParent != true)
        }
    }

    @ViewBuilder
    private var depositSheetContent: some View {
        if let vm = viewModel {
            HeroTransactionView(mode: .deposit, viewModel: vm, heroName: hero.displayName)
        }
    }

    @ViewBuilder
    private var withdrawSheetContent: some View {
        if let vm = viewModel {
            HeroTransactionView(mode: .withdraw, viewModel: vm, heroName: hero.displayName)
        }
    }

    @ViewBuilder
    private var exportDialogContent: some View {
        Button("Export as CSV") { exportEntries(as: .csv) }
        Button("Export as JSON") { exportEntries(as: .json) }
        Button("Cancel", role: .cancel) {}
    }

    @ViewBuilder
    private var shareSheetContent: some View {
        if let url = shareURL {
            ShareSheet(items: [url])
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

    private enum ExportFormat { case csv, json }

    private func exportEntries(as format: ExportFormat) {
        // cachedLedgers is already profile-scoped via predicate pushdown.
        let filtered = cachedLedgers.filter { scope.contains($0.date, payoutDay: payoutDay) }

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

    @ViewBuilder
    private var ledgerList: some View {
        if let vm = viewModel {
            if vm.ledgerRows.isEmpty {
                EmptyStateView(
                    systemImage: "scroll.fill",
                    title: "Empty Scroll",
                    description: scope.emptyStateCopy,
                    topPadding: 32
                )
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(vm.ledgerRows) { entry in
                        heroLedgerEntryRow(entry)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func heroLedgerEntryRow(_ entry: SpendingLogRow) -> some View {
        VStack(spacing: 4) {
            entryCardContent(entry)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(DesignSystemConstants.Colors.cardSurface))
                )
        }
    }

    private func entryCardContent(_ entry: SpendingLogRow) -> some View {
        let iconInfo: (name: String, color: Color) = LedgerRowStyle.sourceIcon(for: entry.source, fallbackTint: .primary)
        return HStack(alignment: .top, spacing: 12) {
            entryIcon(iconInfo: iconInfo)
            entryDetails(entry, sourceColor: iconInfo.color)
            Spacer(minLength: 12)
            entryAmount(entry.amount)
        }
    }

    private func entryIcon(iconInfo: (name: String, color: Color)) -> some View {
        entryIconView(name: iconInfo.name, color: iconInfo.color)
    }

    private func entryIconView(name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.title2)
            .foregroundStyle(color)
            .frame(width: 32)
    }

    private func entryDetails(_ entry: SpendingLogRow, sourceColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.description)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            if let location = entry.location, !location.isEmpty {
                entryLocationRow(location)
            }
            entryMetaRow(entry, sourceColor: sourceColor)
        }
    }

    private func entryLocationRow(_ location: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "mappin.and.ellipse")
                .font(.caption2)
            Text(location)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(.secondary)
    }

    private func entryMetaRow(_ entry: SpendingLogRow, sourceColor: Color) -> some View {
        HStack(spacing: 6) {
            entrySourceLabel(entry, sourceColor: sourceColor)
            if let bucket = entry.bucketKindEnum {
                dotSeparator
                bucketBadge(bucket)
            }
            dotSeparator
            Text(LedgerRowStyle.dateText(for: entry.date))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func entrySourceLabel(_ entry: SpendingLogRow, sourceColor: Color) -> some View {
        Text(LedgerRowStyle.sourceLabel(for: entry.source))
            .font(.caption.weight(.medium))
            .foregroundStyle(sourceColor)
    }

    private var dotSeparator: some View {
        Text("•")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func bucketBadge(_ bucket: BucketKind) -> some View {
        HStack(spacing: 3) {
            Image(systemName: bucket.iconSystemName)
                .font(.system(size: 9))
            Text(bucket.shortName)
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(Color(DesignSystemConstants.Colors.accentBlue).opacity(0.12))
        )
        .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
    }

    private func entryAmount(_ amount: Int64) -> some View {
        Text(CurrencyFormatter.signed(amount))
            .font(.subheadline.weight(.bold).monospacedDigit())
            .foregroundStyle(amount >= 0 ? Color(DesignSystemConstants.Colors.gold) : Color(DesignSystemConstants.Colors.dangerRed))
    }
}
