//
//  PayoutHistoryView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

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

    @Query private var cachedAllowancePeriods: [AllowancePeriodCache]
    @Query private var cachedProfiles: [ProfileCache]
    @Query private var cachedAchievements: [AchievementCache]
    @Query private var cachedProfileAchievements: [ProfileAchievementCache]
    @Query private var cachedLedgers: [LedgerEntryCache]

    @State private var viewModel: FamilyDashboardViewModel?
    @State private var selectedPeriod: AllowancePeriodCache?

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
    }

    var body: some View {
        NavigationStack {
            contentList
                .background(Color(.systemGroupedBackground).ignoresSafeArea())
                .navigationTitle("Payout History")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showImportSheet = true
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                        }
                        // Import is a privileged parent mutation, matching the
                        // service-layer authorization in LedgerImportService.
                        .disabled(appState.currentProfile?.role.isParent != true)
                        .accessibilityLabel("Import Transactions")
                        .accessibilityIdentifier("payoutHistory.importButton")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showExportPicker = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .disabled(appState.currentProfile?.role.isParent != true)
                    }
                }
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
                        familyRecordName: familyRecordName
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
                .sheet(item: $selectedPeriod) { period in
                    PayoutDetailSheet(period: period, heroName: heroName(for: period))
                }
        }
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
        }, rebuild: { _ in rebuildFromCache() })
    }

    private func rebuildFromCache() {
        // The `@Query` declarations above already filter by
        // `familyRecordName` at the SwiftData/SQLite layer, so we no longer
        // post-filter the cached rows in Swift. Pass them straight through.
        viewModel?.rebuildLists(
            profiles: cachedProfiles,
            quests: [],
            logs: [],
            ledgers: [],
            allowancePeriods: cachedAllowancePeriods,
            profileAchievements: cachedProfileAchievements,
            achievements: cachedAchievements
        )
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

    private var filteredPayouts: [AllowancePeriodCache] {
        guard let payouts = viewModel?.pastPayouts else { return [] }
        return payouts.sorted { $0.weekOf > $1.weekOf }
    }

    private func payoutRow(_ period: AllowancePeriodCache) -> some View {
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
                Text(CurrencyFormatter.string(period.totalEarned))
                    .font(.subheadline.weight(.bold).monospacedDigit())

                statusBadge(for: period.statusEnum ?? .payoutPending)
            }
        }
        .contentShape(Rectangle())
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
        return VStack(spacing: 12) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No Payout History Yet")
                .font(.headline)
            Text("Payouts occur every \(payoutDayName) when quests are tallied.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
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

private struct PayoutDetailSheet: View {
    let period: AllowancePeriodCache
    let heroName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Summary") {
                    LabeledContent("Hero", value: heroName)
                    LabeledContent("Week Of", value: period.weekOf.formatted(.dateTime.month().day().year()))
                    LabeledContent("Status", value: (period.statusEnum ?? .payoutPending).displayName)
                    LabeledContent("Quests Completed", value: "\(period.questsCompleted) of \(period.questsTotal)")
                    LabeledContent("Total Earned", value: CurrencyFormatter.string(period.totalEarned))
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

// MARK: - Export Child Picker

/// Sheet that lets a parent pick a child, optionally set a date range, and
/// confirm the export. All-time range is the default; a toggle reveals the
/// start/end date pickers.
private struct ExportChildPickerSheet: View {
    let heroes: [ProfileCache]
    let onExport: (ProfileCache, Date, Date) -> Void

    @State private var selectedChild: ProfileCache?
    @State private var useDateFilter = false
    @State private var startDate = Date.distantPast
    @State private var endDate = Date()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Select Child") {
                    if heroes.isEmpty {
                        Text("No children in this family.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Child", selection: $selectedChild) {
                            Text("Choose a child…").tag(nil as ProfileCache?)
                            ForEach(heroes, id: \.recordName) { hero in
                                Text(hero.displayName).tag(hero as ProfileCache?)
                            }
                        }
                    }
                }

                Section("Date Range (Optional)") {
                    Toggle("Filter by date range", isOn: $useDateFilter)
                    if useDateFilter {
                        DatePicker("Start", selection: $startDate, displayedComponents: .date)
                        DatePicker("End", selection: $endDate, displayedComponents: .date)
                    } else {
                        Text("All-time (no date filtering)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Export Ledger")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Export") {
                        guard let child = selectedChild else { return }
                        dismiss()
                        let effectiveStart = useDateFilter ? startDate : Date.distantPast
                        let effectiveEnd = useDateFilter ? endDate : Date.distantFuture
                        onExport(child, effectiveStart, effectiveEnd)
                    }
                    .disabled(selectedChild == nil)
                }
            }
        }
        .onAppear {
            // Pre-select the first hero if none is chosen yet.
            if selectedChild == nil, let first = heroes.first {
                selectedChild = first
            }
        }
    }
}
