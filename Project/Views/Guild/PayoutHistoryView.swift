//
//  PayoutHistoryView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Charts
import SwiftData
import SwiftUI

struct PayoutHistoryView: View {
    @Environment(AppState.self) private var appState
    @Environment(QuestService.self) private var questService
    @Environment(TreasuryService.self) private var treasury
    @Environment(AchievementService.self) private var achievementService
    @Environment(FamilyService.self) private var familyService
    @Environment(LedgerImportService.self) private var ledgerImportService
    @Environment(ToastManager.self) private var toastManager: ToastManager?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @Query private var cachedAllowancePeriods: [AllowancePeriodCache]
    @Query private var cachedProfiles: [ProfileCache]
    @Query private var cachedAchievements: [AchievementCache]
    @Query private var cachedProfileAchievements: [ProfileAchievementCache]
    @Query private var cachedLedgers: [LedgerEntryCache]
    @Query private var cachedGoals: [GoalCache]

    @State private var viewModel: FamilyDashboardViewModel?
    @State private var selectedPeriod: AllowancePeriodCache?
    @State private var selectedHeroRecordName: String?
    @AppStorage("payoutHistory.calendarScope") private var scope: CalendarScope = .allTime
    @State private var searchText = ""

    @State private var showExportPicker = false
    @State private var showExportSheet = false
    @State private var showShareSheet = false
    @State private var shareURL: URL?
    @State private var exportFormat: ExportFormat?
    @State private var showImportSheet = false
    private let exportService = LedgerExportService()

    /// Family record name used to push the family filter down to SwiftData.
    /// When `nil` (no family loaded) the queries return zero rows, which is
    /// the correct behavior — there is no family to scope to.
    private let familyRecordName: String?

    init(familyRecordName: String? = nil) {
        self.familyRecordName = familyRecordName

        // Filter queries by family at the SwiftData store layer. When familyRecordName is nil,
        // scope to an empty string ("") so zero rows are returned rather than fetching unscoped across all families.
        let targetFamily = familyRecordName ?? ""
        let allowanceFilter = #Predicate<AllowancePeriodCache> { $0.familyRecordName == targetFamily }
        let profileFilter = #Predicate<ProfileCache> { $0.familyRecordName == targetFamily }
        let achievementFilter = #Predicate<AchievementCache> { $0.familyRecordName == targetFamily }
        let profileAchievementFilter = #Predicate<ProfileAchievementCache> { $0.familyRecordName == targetFamily }
        let ledgerFilter = #Predicate<LedgerEntryCache> { $0.familyRecordName == targetFamily }
        let goalFilter = #Predicate<GoalCache> { $0.familyRecordName == targetFamily }
        _cachedAllowancePeriods = Query(
            filter: allowanceFilter,
            sort: \AllowancePeriodCache.weekOf,
            order: .reverse
        )
        _cachedProfiles = Query(
            filter: profileFilter,
            sort: \ProfileCache.displayName
        )
        _cachedAchievements = Query(
            filter: achievementFilter,
            sort: \AchievementCache.name
        )
        _cachedProfileAchievements = Query(
            filter: profileAchievementFilter,
            sort: \ProfileAchievementCache.earnedDate,
            order: .reverse
        )
        _cachedLedgers = Query(
            filter: ledgerFilter,
            sort: \LedgerEntryCache.date,
            order: .reverse
        )
        _cachedGoals = Query(
            filter: goalFilter,
            sort: \GoalCache.createdAt
        )
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularLayout
            } else {
                compactLayout
            }
        }
        .background(Color(DesignSystemConstants.Colors.background).ignoresSafeArea())
        .confirmationDialog("Export Ledger", isPresented: $showExportPicker) {
            Button("Export as CSV") {
                exportFormat = .csv
                showExportSheet = true
            }
            Button("Export as JSON") {
                exportFormat = .json
                showExportSheet = true
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showExportSheet) {
            ExportChildPickerSheet(
                heroes: heroProfiles,
                onExport: { child, startDate, endDate in
                    performExport(for: child, startDate: startDate, endDate: endDate)
                }
            )
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = shareURL {
                ShareSheet(items: [url])
            }
        }
        .sheet(isPresented: $showImportSheet) {
            LedgerImportView(
                importService: ledgerImportService,
                familyRecordName: familyRecordName ?? appState.family?.id.recordName
            )
        }
        .task {
            ensureViewModel()
            await viewModel?.refresh()
        }
        .refreshable {
            rebuildFromCache()
        }
        .onChange(of: cachedAllowancePeriods) { _, _ in rebuildFromCache() }
        .onChange(of: cachedProfiles) { _, _ in rebuildFromCache() }
        .onChange(of: cachedAchievements) { _, _ in rebuildFromCache() }
        .onChange(of: cachedProfileAchievements) { _, _ in rebuildFromCache() }
        .onChange(of: cachedLedgers) { _, _ in rebuildFromCache() }
        .onChange(of: cachedGoals) { _, _ in }
    }

    // MARK: - Layouts

    private var regularLayout: some View {
        ViewThatFitsSplit {
            NavigationSplitView {
                sidebarContent
                    .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 380)
                    .searchable(text: $searchText, prompt: "Search payouts")
                    .toolbar { payoutToolbar }
                    .navigationTitle("Payout History")
                    .navigationBarTitleDisplayMode(.large)
            } detail: {
                detailPane
                    .toolbar { payoutToolbar }
                    .navigationTitle(selectedPeriod != nil ? "Payout Detail" : "Payout History")
                    .navigationBarTitleDisplayMode(.inline)
                    .background(Color(DesignSystemConstants.Colors.background))
            }
            .navigationSplitViewStyle(.balanced)
        } compactContent: {
            compactLayout
        }
    }

    private var compactLayout: some View {
        NavigationStack {
            compactContentList
                .background(Color(DesignSystemConstants.Colors.background).ignoresSafeArea())
                .navigationTitle("Payout History")
                .navigationBarTitleDisplayMode(.large)
                .searchable(text: $searchText, prompt: "Search payouts")
                .toolbar { payoutToolbar }
                .sheet(item: $selectedPeriod) { period in
                    PayoutDetailSheet(
                        period: period,
                        heroName: heroName(for: period),
                        ledgerEntries: cachedLedgers.filter { $0.profileRecordName == period.profileRecordName },
                        goals: cachedGoals.filter { $0.profileRecordName == period.profileRecordName }
                    )
                }
        }
    }

    // MARK: - Toolbar (extracted to help Swift 6 type-checker on Xcode 26.6)

    @ToolbarContentBuilder
    private var payoutToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { importButton }
        ToolbarItem(placement: .primaryAction) { exportButton }
    }

    private var importButton: some View {
        Button {
            showImportSheet = true
        } label: {
            Image(systemName: "square.and.arrow.down")
        }
        .disabled(appState.currentProfile?.role.isParent != true)
        .accessibilityLabel("Import Transactions")
        .accessibilityIdentifier("payoutHistory.importButton")
    }

    private var exportButton: some View {
        Button {
            showExportPicker = true
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .disabled(appState.currentProfile?.role.isParent != true)
    }

    private func ensureViewModel() {
        ViewLifecycle.ensureAndRebuild(&viewModel, factory: {
            FamilyDashboardViewModel(
                questService: questService,
                treasury: treasury,
                achievementService: achievementService,
                familyService: familyService,
                appState: appState
            )
        }, rebuild: { vm in rebuildFromCache(vm) })
    }

    private func rebuildFromCache(_ vm: FamilyDashboardViewModel? = nil) {
        // The `@Query` declarations above already filter by
        // `familyRecordName` at the SwiftData/SQLite layer, so we no longer
        // post-filter the cached rows in Swift. Pass them straight through.
        (vm ?? viewModel)?.rebuildLists(
            profiles: cachedProfiles,
            quests: [],
            logs: [],
            ledgers: [],
            allowancePeriods: cachedAllowancePeriods,
            profileAchievements: cachedProfileAchievements,
            achievements: cachedAchievements
        )
    }

    // MARK: - Sidebar (regular)

    @ViewBuilder
    private var sidebarContent: some View {
        let payouts = filteredPayouts
        if payouts.isEmpty, viewModel?.pastPayouts.isEmpty ?? true {
            emptyState
        } else {
            VStack(spacing: 0) {
                filterSection
                Divider()
                if payouts.isEmpty {
                    noFilteredResultsView
                } else {
                    List {
                        payoutRowsList(payouts: payouts, highlightSelection: true)
                    }
                    .listStyle(.plain)
                    .background(Color(DesignSystemConstants.Colors.background))
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color(DesignSystemConstants.Colors.background))
        }
    }

    private var payoutDay: PayoutDay {
        appState.family?.payoutDay ?? .sunday
    }

    private var filterSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    heroChip(title: "All", isSelected: selectedHeroRecordName == nil) {
                        selectedHeroRecordName = nil
                    }
                    ForEach(heroProfiles, id: \.recordName) { hero in
                        heroChip(title: hero.displayName, isSelected: selectedHeroRecordName == hero.recordName) {
                            selectedHeroRecordName = hero.recordName
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            CalendarScopeFilterView(scope: $scope, payoutDay: payoutDay)
                .padding(.horizontal, 12)
                .padding(.bottom, 2)
        }
        .background(Color(DesignSystemConstants.Colors.background))
    }

    private func heroChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(isSelected ? Color(DesignSystemConstants.Colors.accentBlue) : Color(DesignSystemConstants.Colors.cardSurface))
                )
                // WHY white on selected chip: accentBlue fill needs white text for contrast in both modes.
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .overlay(
                    Capsule()
                        .strokeBorder(isSelected ? Color(DesignSystemConstants.Colors.cardSurface).opacity(0) : Color.secondary.opacity(0.2), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("payoutHistory.heroChip.\(title)")
    }

    // MARK: - Shared payout list helpers (DRY — single source for filterSection, row, and filtered state)

    private var noFilteredResultsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No payouts match filters")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(DesignSystemConstants.Colors.background))
    }

    private func payoutRowsList(payouts: [AllowancePeriodCache], highlightSelection: Bool) -> some View {
        ForEach(payouts) { period in
            Button {
                selectedPeriod = period
            } label: {
                payoutRow(period)
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .contextMenu {
                Button {
                    selectedPeriod = period
                } label: {
                    Label("View Detail", systemImage: "eye")
                }
            }
            .listRowBackground(
                highlightSelection && selectedPeriod?.recordName == period.recordName
                    ? Color(DesignSystemConstants.Colors.accentBlue).opacity(0.12)
                    : Color(DesignSystemConstants.Colors.cardSurface)
            )
        }
    }

    // MARK: - Detail Pane (regular)

    @ViewBuilder
    private var detailPane: some View {
        if let period = selectedPeriod {
            PayoutDetailContent(
                period: period,
                heroName: heroName(for: period),
                ledgerEntries: cachedLedgers.filter { $0.profileRecordName == period.profileRecordName },
                goals: cachedGoals.filter { $0.profileRecordName == period.profileRecordName },
                cachedLedgers: cachedLedgers,
                chartData: chartData(for: period),
                aggregatedChartData: aggregatedChartData
            )
        } else {
            aggregatedPlaceholder
        }
    }

    private var aggregatedPlaceholder: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "chart.bar.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.tertiary)
                        Text("Select a payout")
                            .font(.headline)
                        Text("Choose a period from the list to view its ledger and bucket breakdown.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } header: {
                    PayoutChartHeader(data: aggregatedChartData)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(Color(DesignSystemConstants.Colors.background))
                }
            }
            .maxContentWidth()
            .padding(.vertical, 8)
        }
        .background(Color(DesignSystemConstants.Colors.background))
    }

    // MARK: - Compact content

    @ViewBuilder
    private var compactContentList: some View {
        let payouts = filteredPayouts
        if payouts.isEmpty, viewModel?.pastPayouts.isEmpty ?? true {
            emptyState
        } else {
            VStack(spacing: 0) {
                filterSection
                Divider()
                if payouts.isEmpty {
                    noFilteredResultsView
                } else {
                    List {
                        payoutRowsList(payouts: payouts, highlightSelection: false)
                    }
                    .listStyle(.insetGrouped)
                    .background(Color(DesignSystemConstants.Colors.background))
                    .scrollContentBackground(.hidden)
                }
            }
        }
    }

    private var filteredPayouts: [AllowancePeriodCache] {
        guard let payouts = viewModel?.pastPayouts else { return [] }
        var result = payouts
        if let hero = selectedHeroRecordName {
            result = result.filter { $0.profileRecordName == hero }
        }
        if scope != .allTime {
            result = result.filter { scope.contains($0.weekOf, payoutDay: payoutDay) }
        }
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let lower = trimmed.lowercased()
            result = result.filter {
                heroName(for: $0).lowercased().contains(lower) ||
                    $0.statusEnum?.displayName.lowercased().contains(lower) == true
            }
        }
        return result.sorted { $0.weekOf > $1.weekOf }
    }

    private func payoutRow(_ period: AllowancePeriodCache) -> some View {
        HStack(spacing: DesignSystemConstants.Padding.medium) {
            VStack(alignment: .leading, spacing: DesignSystemConstants.Padding.small) {
                Text(period.weekOf, format: .dateTime.month().day().year())
                    .font(.subheadline.bold())
                    .monospacedDigit()
                Text(heroName(for: period))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: DesignSystemConstants.Padding.small) {
                Text(CurrencyFormatter.string(period.totalEarned))
                    .font(.subheadline.weight(.bold).monospacedDigit())

                statusBadge(for: period.statusEnum ?? .payoutPending)
            }
        }
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
        .padding(.vertical, DesignSystemConstants.Padding.small)
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
        case .paid: Color(DesignSystemConstants.Colors.primaryGreen)
        case .payoutPending: Color(DesignSystemConstants.Colors.pendingAmber)
        case .active: Color(DesignSystemConstants.Colors.accentBlue)
        }
    }

    private func heroName(for period: AllowancePeriodCache) -> String {
        let match = viewModel?.heroes.first { $0.recordName == period.profileRecordName }
        return match?.displayName ?? "Hero"
    }

    private var emptyState: some View {
        let payoutDayName = appState.family?.payoutDay.displayName ?? "Sunday"
        return VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: DesignSystemConstants.Padding.medium) {
                    PayoutChartHeader(data: [])
                        .padding(.horizontal, DesignSystemConstants.Padding.standard)
                        .padding(.top, DesignSystemConstants.Padding.standard)
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                        .padding(.top, DesignSystemConstants.Padding.xlarge)
                    Text("No Payout History Yet")
                        .font(.headline)
                    Text("Payouts occur every \(payoutDayName) when quests are tallied.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, DesignSystemConstants.Padding.xlarge)
                }
                .maxBannerWidth()
                .padding(.vertical, DesignSystemConstants.Padding.xlarge)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(DesignSystemConstants.Colors.background))
    }

    // MARK: - Chart data

    private func chartData(for period: AllowancePeriodCache) -> [WeeklyEarningPoint] {
        guard let all = viewModel?.pastPayouts else { return [] }
        let filtered = all.filter { $0.profileRecordName == period.profileRecordName }
            .sorted { $0.weekOf < $1.weekOf }
        let last12 = Array(filtered.suffix(12))
        return last12.map { payoutPeriod in
            WeeklyEarningPoint(
                id: payoutPeriod.recordName,
                weekStart: payoutPeriod.weekOf,
                label: payoutPeriod.weekOf.formatted(.dateTime.month(.abbreviated).day()),
                amount: payoutPeriod.totalEarned,
                isPaid: payoutPeriod.statusEnum == .paid
            )
        }
    }

    private var aggregatedChartData: [WeeklyEarningPoint] {
        guard let all = viewModel?.pastPayouts, !all.isEmpty else { return [] }
        // Group by normalized weekOf to combine multi-hero same-week payouts.
        let grouped = Dictionary(grouping: all) { WeekMath.startOfWeek(for: $0.weekOf, payoutDay: payoutDay) }
        let sortedWeeks = grouped.keys.sorted()
        let last12Weeks = sortedWeeks.suffix(12)
        return last12Weeks.map { week in
            let periods = grouped[week] ?? []
            let total = periods.reduce(0.0) { $0 + $1.totalEarned }
            let isPaid = periods.allSatisfy { $0.statusEnum == .paid }
            return WeeklyEarningPoint(id: WeekMath.dayKey(for: week), weekStart: week, label: week.formatted(.dateTime.month(.abbreviated).day()), amount: total, isPaid: isPaid)
        }
    }

    // MARK: - Export

    private enum ExportFormat { case csv, json }

    /// Hero-role profiles for the child picker during export.
    private var heroProfiles: [ProfileCache] {
        cachedProfiles.filter { $0.roleEnum == .hero }
    }

    private func performExport(for child: ProfileCache, startDate: Date, endDate: Date) {
        guard let format = exportFormat else { return }

        let range = startDate ... endDate
        let childLedgers = cachedLedgers.filter {
            $0.profileRecordName == child.recordName && range.contains($0.date)
        }

        let data: Data
        switch format {
        case .csv:
            data = exportService.buildCSV(entries: childLedgers, childName: child.displayName)
        case .json:
            do {
                data = try exportService.buildJSON(entries: childLedgers)
            } catch {
                toastManager?.show(message: "Could not build JSON export.", type: .error)
                return
            }
        }

        let ext = format == .csv ? "csv" : "json"
        let name = LedgerExportService.filename(child: child.displayName, date: Date(), ext: ext)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: tempURL, options: .atomic)
            shareURL = tempURL
            showExportSheet = false
            showShareSheet = true
        } catch {
            toastManager?.show(message: "Could not write export file.", type: .error)
        }
    }
}
