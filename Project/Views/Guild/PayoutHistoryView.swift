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
    @State private var selectedPeriod: AllowancePeriodCache?

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
            contentList
                .background(Color(.systemGroupedBackground).ignoresSafeArea())
                .navigationTitle("Payout History")
                .navigationBarTitleDisplayMode(.large)
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
