//
//  PayoutHistoryView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import SwiftData
import SwiftUI

struct PayoutHistoryView: View {
    @Environment(AppState.self) private var appState
    @Environment(QuestService.self) private var questService
    @Environment(TreasuryService.self) private var treasury
    @Environment(AchievementService.self) private var achievementService
    @Environment(FamilyService.self) private var familyService

    @Query private var cachedAllowancePeriods: [AllowancePeriodCache]
    @Query private var cachedProfiles: [ProfileCache]
    @Query private var cachedAchievements: [AchievementCache]
    @Query private var cachedProfileAchievements: [ProfileAchievementCache]

    @State private var viewModel: FamilyDashboardViewModel?
    @State private var filter: PayoutFilter = .all
    @State private var selectedPeriod: AllowancePeriodCache?

    /// Family record name used to push the family filter down to SwiftData.
    /// When `nil` (no family loaded) the queries return zero rows, which is
    /// the correct behavior — there is no family to scope to.
    private let familyRecordName: String?

    enum PayoutFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case paid = "Paid"
        var id: String {
            rawValue
        }
    }

    init(familyRecordName: String? = nil) {
        self.familyRecordName = familyRecordName

        // so we don't fetch every family's rows and post-filter in Swift.
        // Mirrors the L1 branch style in `CacheService.upsertX`: nil family
        // means "no filter", non-nil means "filter by family". We do NOT use
        // the banned `familyRecordName ?? ""` sentinel — that conflicts with
        let allowanceFilter: Predicate<AllowancePeriodCache>? = familyRecordName.map { name in
            #Predicate { $0.familyRecordName == name }
        }
        let profileFilter: Predicate<ProfileCache>? = familyRecordName.map { name in
            #Predicate { $0.familyRecordName == name }
        }
        let achievementFilter: Predicate<AchievementCache>? = familyRecordName.map { name in
            #Predicate { $0.familyRecordName == name }
        }
        let profileAchievementFilter: Predicate<ProfileAchievementCache>? = familyRecordName.map { name in
            #Predicate { $0.familyRecordName == name }
        }
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
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterPicker
                contentList
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Payout History")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                if viewModel == nil {
                    viewModel = FamilyDashboardViewModel(
                        questService: questService,
                        treasury: treasury,
                        achievementService: achievementService,
                        familyService: familyService,
                        appState: appState
                    )
                }

                // snapshot. `pastPayouts` is derived inside `rebuildLists`
                // from `cachedAllowancePeriods` (replaces the deleted
                // `loadPastPayouts()` cache-fetch path). `heroes` is populated
                // from `cachedProfiles` so `heroName(for:)` resolves.
                Task { await viewModel?.refresh() }
                rebuildFromCache()
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

    private var filterPicker: some View {
        Picker("Filter", selection: $filter) {
            ForEach(PayoutFilter.allCases) { payoutFilter in
                Text(payoutFilter.rawValue).tag(payoutFilter)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.systemGroupedBackground))
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
        let sorted = payouts.sorted { $0.weekOf > $1.weekOf }
        switch filter {
        case .all: return sorted
        case .paid: return sorted.filter { $0.status == PayoutStatus.paid.rawValue }
        }
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
                Text(String(format: "%.2f gold", period.totalEarned))
                    .font(.subheadline.weight(.bold).monospacedDigit())

                statusBadge(for: period.statusEnum)
            }
        }
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
        case .paid: .green
        case .payoutPending: .orange
        case .active: .blue
        }
    }

    private func heroName(for period: AllowancePeriodCache) -> String {
        let match = viewModel?.heroes.first { $0.recordName == period.profileRecordName }
        return match?.displayName ?? "Hero"
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No Payout History Yet")
                .font(.headline)
            Text("Payouts occur every Sunday when quests are tallied.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
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
                    LabeledContent("Status", value: period.statusEnum.displayName)
                    LabeledContent("Quests Completed", value: "\(period.questsCompleted) of \(period.questsTotal)")
                    LabeledContent("Total Gold Earned", value: String(format: "%.2f", period.totalEarned))
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
