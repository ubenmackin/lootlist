//
//  SpendingLogView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import SwiftData
import SwiftUI

struct SpendingLogView: View {
    @Bindable var viewModel: TreasuryViewModel
    @Binding var scope: CalendarScope
    @Environment(AppState.self) private var appState

    @State private var selectedGroup: TransactionGroup?
    /// Nil shows All; non-nil filters the ledger list to that bucket's attribution.
    @State private var selectedBucketFilter: BucketKind?

    private let familyRecordName: String?
    private let profileRecordName: String?

    @Query private var cachedLedgers: [LedgerEntryCache]

    init(viewModel: TreasuryViewModel, familyRecordName: String? = nil, profileRecordName: String? = nil, scope: Binding<CalendarScope>) {
        self.viewModel = viewModel
        _scope = scope
        self.familyRecordName = familyRecordName
        self.profileRecordName = profileRecordName
        let targetFamily = familyRecordName ?? ""
        let targetProfile = profileRecordName ?? ""
        let ledgerFilter = LedgerEntryCache.profilePredicate(familyRecordName: targetFamily, profileRecordName: targetProfile)
        _cachedLedgers = Query(
            filter: ledgerFilter,
            sort: \LedgerEntryCache.date,
            order: .reverse
        )
    }

    private var resolvedProfileName: String {
        // WHY explicit profile: never fall back to the first ledger row, which would collapse a parent view to one hero.
        profileRecordName ?? ""
    }

    private var isMissingProfile: Bool {
        resolvedProfileName.isEmpty
    }

    private var payoutDay: PayoutDay {
        appState.resolvedPayoutDay
    }

    private var groups: [TransactionGroup] {
        // WHY single truth: grouping plus running totals live in the view model so the log never rebuilds beside it.
        guard let filter = selectedBucketFilter else { return viewModel.spendingGroups }
        return viewModel.spendingGroups.compactMap { TransactionGroupBuilder.filteredGroup($0, for: filter) }
    }

    private var bucketBalances: [BucketKind: Int64] {
        // WHY cache-first: header tiles reuse the queried rows so totals match the ledger list.
        BucketService.bucketBalances(for: cachedLedgers, profileRecordName: resolvedProfileName)
    }

    private var totalBalance: Int64 {
        BucketService.totalBalance(bucketBalances: bucketBalances)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                LedgerStaleBanner(familyRecordName: familyRecordName, count: cachedLedgers.count)
                    .padding(.horizontal)
                if !isMissingProfile {
                    balanceHeader
                        .padding(.horizontal)
                }
                CalendarScopeFilterView(scope: $scope, payoutDay: payoutDay)
                    .padding(.horizontal)

                if isMissingProfile {
                    missingProfileState
                } else if groups.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(groups) { group in
                            LedgerGroupRowView(
                                group: group,
                                selectedBucketFilter: selectedBucketFilter,
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
            .padding(.vertical)
        }
        .background(Color(DesignSystemConstants.Colors.background))
        .navigationTitle("Scroll of Spending")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: scope) { _, newScope in
            // WHY single identity: header and groups share resolvedProfileName, so skip fallback rebuilds while missing.
            guard !isMissingProfile else { return }
            viewModel.rebuildSpendingLog(from: cachedLedgers, scope: newScope, profileRecordName: resolvedProfileName)
        }
        .onChange(of: cachedLedgers) { _, newLedgers in
            guard !isMissingProfile else { return }
            viewModel.rebuildSpendingLog(from: newLedgers, scope: scope, profileRecordName: resolvedProfileName)
        }
        .task {
            guard !isMissingProfile else { return }
            viewModel.rebuildSpendingLog(from: cachedLedgers, scope: scope, profileRecordName: resolvedProfileName)
        }
        .sheet(item: $selectedGroup) { group in
            LedgerGroupDetailSheet(group: group, selectedBucketFilter: selectedBucketFilter)
        }
    }

    private var emptyState: some View {
        EmptyStateView(
            systemImage: "scroll.fill",
            title: LedgerEmptyState.title(for: selectedBucketFilter, defaultTitle: "Empty Ledger"),
            description: scope.emptyStateCopy,
            topPadding: 64
        )
    }

    private var missingProfileState: some View {
        // WHY explicit profile: without a hero scope the log cannot attribute buckets, so require selection instead of first-row fallback.
        EmptyStateView(
            systemImage: "person.crop.circle.badge.questionmark",
            title: "Select a Hero",
            description: "Choose a hero to view their Scroll of Spending.",
            topPadding: 64
        )
    }

    private var balanceHeader: some View {
        LedgerBalanceHeaderView(
            totalBalance: totalBalance,
            bucketBalances: bucketBalances,
            selectedBucketFilter: selectedBucketFilter,
            onSelectTotal: { selectedBucketFilter = nil },
            onSelectBucket: { selectedBucketFilter = LedgerBucketFilter.toggled(selectedBucketFilter, with: $0) }
        )
    }
}
