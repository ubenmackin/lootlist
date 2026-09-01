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

    init(hero: ProfileCache, familyRecordName: String?, spending: SpendingService) {
        self.hero = hero
        self.familyRecordName = familyRecordName
        self.spending = spending
        let targetFamily = familyRecordName ?? ""
        let targetProfile = hero.recordName
        let ledgerFilter = #Predicate<LedgerEntryCache> { $0.familyRecordName == targetFamily && $0.profileRecordName == targetProfile }
        let questFilter = #Predicate<QuestCache> { $0.familyRecordName == targetFamily && $0.assigneeRecordName == targetProfile && $0.isActive == true }
        let completionFilter = #Predicate<QuestCompletionCache> { $0.familyRecordName == targetFamily && $0.completerRecordName == targetProfile }
        let allowancePeriodFilter = #Predicate<AllowancePeriodCache> { $0.familyRecordName == targetFamily && $0.profileRecordName == targetProfile }

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
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                BalanceCardView(
                    balance: viewModel?.balance,
                    weekOf: nil,
                    status: nil,
                    pendingPayoutAmount: viewModel?.pendingQuestGold
                )

                CalendarScopeFilterView(
                    scope: $scope,
                    payoutDay: hero.payoutDayEnum ?? appState.family?.payoutDay ?? .sunday
                )
                .padding(.horizontal)

                HStack(spacing: 12) {
                    depositButton
                    withdrawButton
                }
                .padding(.horizontal)

                ledgerList
            }
            .padding(.vertical)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Treasury")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { ensureViewModel() }
        .task { ensureViewModel() }
        .onChange(of: cachedLedgers) { _, _ in rebuild() }
        .onChange(of: cachedQuests) { _, _ in rebuild() }
        .onChange(of: cachedCompletions) { _, _ in rebuild() }
        .onChange(of: cachedAllowancePeriods) { _, _ in rebuild() }
        .onChange(of: scope) { _, _ in rebuild() }
        .sheet(isPresented: $isShowingDeposit) {
            if let vm = viewModel {
                HeroTransactionView(mode: .deposit, viewModel: vm, heroName: hero.displayName)
            }
        }
        .sheet(isPresented: $isShowingWithdraw) {
            if let vm = viewModel {
                HeroTransactionView(mode: .withdraw, viewModel: vm, heroName: hero.displayName)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showExportPicker = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                // Disable the export button when the acting user is not a parent.
                .disabled(appState.currentProfile?.role.isParent != true)
            }
        }
        .confirmationDialog("Export Ledger", isPresented: $showExportPicker) {
            Button("Export as CSV") { exportEntries(as: .csv) }
            Button("Export as JSON") { exportEntries(as: .json) }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = shareURL {
                ShareSheet(items: [url])
            }
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
            scope: scope
        )
    }

    // MARK: - Export

    private enum ExportFormat { case csv, json }

    private func exportEntries(as format: ExportFormat) {
        // cachedLedgers is already profile-scoped via predicate pushdown.
        let payoutDay = hero.payoutDayEnum ?? appState.family?.payoutDay ?? .sunday
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
                    .fill(Color(.secondarySystemGroupedBackground))
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
                    .fill(Color(.secondarySystemGroupedBackground))
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
            HStack(alignment: .top, spacing: 12) {
                let iconInfo = LedgerRowStyle.sourceIcon(for: entry.source, fallbackTint: .primary)
                Image(systemName: iconInfo.name)
                    .font(.title2)
                    .foregroundStyle(iconInfo.color)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.description)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    if let location = entry.location, !location.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.caption2)
                            Text(location)
                                .font(.caption.weight(.medium))
                        }
                        .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Text(LedgerRowStyle.sourceLabel(for: entry.source))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(iconInfo.color)
                        if let bucket = entry.bucketKindEnum {
                            Text("•")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
                        Text("•")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(LedgerRowStyle.dateText(for: entry.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 12)

                Text(GoldFormat.signed(entry.amount))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(entry.amount >= 0 ? Color.gold : Color(DesignSystemConstants.Colors.dangerRed))
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
        }
    }
}
