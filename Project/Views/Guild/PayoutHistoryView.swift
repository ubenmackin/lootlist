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

    @Query(sort: \AllowancePeriodCache.weekOf, order: .reverse) private var cachedAllowancePeriods: [AllowancePeriodCache]
    @Query(sort: \ProfileCache.displayName) private var cachedProfiles: [ProfileCache]
    @Query(sort: \AchievementCache.name) private var cachedAchievements: [AchievementCache]
    @Query(sort: \ProfileAchievementCache.earnedDate, order: .reverse) private var cachedProfileAchievements: [ProfileAchievementCache]

    @State private var viewModel: FamilyDashboardViewModel?
    @State private var filter: PayoutFilter = .all
    @State private var selectedPeriod: AllowancePeriodCache?

    enum PayoutFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case paid = "Paid"
        var id: String {
            rawValue
        }
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

                // D3: synchronous render from the current `@Query` cache
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
        guard let familyName = appState.family?.id.recordName else { return }
        viewModel?.rebuildLists(
            profiles: cachedProfiles.filter { $0.familyRecordName == familyName },
            quests: [],
            logs: [],
            ledgers: [],
            allowancePeriods: cachedAllowancePeriods.filter { $0.familyRecordName == familyName },
            profileAchievements: cachedProfileAchievements.filter { $0.familyRecordName == familyName },
            achievements: cachedAchievements.filter { $0.familyRecordName == familyName }
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
                    LabeledContent("Quests Slain", value: "\(period.questsCompleted) of \(period.questsTotal)")
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
