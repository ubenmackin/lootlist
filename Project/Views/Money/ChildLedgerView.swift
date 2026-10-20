//
//  ChildLedgerView.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import os
import SwiftData
import SwiftUI

/// Read-only transaction history for a child profile, grouped by date into daily sections.
struct ChildLedgerView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(AppState.self) private var appState
    @Environment(AppLifecycleCoordinator.self) private var lifecycleCoordinator: AppLifecycleCoordinator?

    private let familyRecordName: String?
    private let profileRecordName: String?

    @State private var isShowingTransfer: Bool = false
    @State private var isShowingSplit: Bool = false
    @State private var selectedGroup: TransactionGroup?
    /// Nil shows All; non-nil filters the ledger list to that bucket's attribution.
    @State private var selectedBucketFilter: BucketKind?

    @Query private var allLedgers: [LedgerEntryCache]

    init(familyRecordName: String? = nil, profileRecordName: String? = nil) {
        self.familyRecordName = familyRecordName
        self.profileRecordName = profileRecordName

        let targetFamily = familyRecordName ?? ""
        FamilyScopeValidator.validateOrFault(targetFamily: targetFamily, viewName: "ChildLedgerView")
        let targetProfile = profileRecordName ?? ""
        let ledgerFilter = LedgerEntryCache.profilePredicate(familyRecordName: targetFamily, profileRecordName: targetProfile)
        _allLedgers = Query(
            filter: ledgerFilter,
            sort: \LedgerEntryCache.date,
            order: .reverse
        )
    }

    // MARK: - Grouped Entries

    private var targetProfileName: String {
        profileRecordName ?? ""
    }

    private var groups: [TransactionGroup] {
        TransactionGroupBuilder.buildGroups(ledgers: allLedgers, profileRecordName: targetProfileName)
    }

    private var bucketBalances: [BucketKind: Int64] {
        // WHY cache-first: header tiles reuse the queried rows so totals match the ledger list.
        BucketService.bucketBalances(for: allLedgers, profileRecordName: targetProfileName)
    }

    private var totalBalance: Int64 {
        BucketService.totalBalance(bucketBalances: bucketBalances)
    }

    private var filteredGroups: [TransactionGroup] {
        guard let filter = selectedBucketFilter else { return groups }
        return groups.compactMap { TransactionGroupBuilder.filteredGroup($0, for: filter) }
    }

    private var dateBuckets: [(title: String, groups: [TransactionGroup])] {
        let payoutDay = appState.resolvedPayoutDay
        let today = Date()
        let thisWeekStart = WeekMath.startOfWeek(for: today, payoutDay: payoutDay)

        var todayGroups: [TransactionGroup] = []
        var yesterdayGroups: [TransactionGroup] = []
        var thisWeekGroups: [TransactionGroup] = []
        var olderGroups: [TransactionGroup] = []

        for group in filteredGroups {
            if WeekMath.isToday(group.date) {
                todayGroups.append(group)
            } else if WeekMath.isYesterday(group.date) {
                yesterdayGroups.append(group)
            } else if WeekMath.startOfWeek(for: group.date, payoutDay: payoutDay) == thisWeekStart {
                thisWeekGroups.append(group)
            } else {
                olderGroups.append(group)
            }
        }

        var buckets: [(title: String, groups: [TransactionGroup])] = []
        if !todayGroups.isEmpty {
            buckets.append(("Today", todayGroups))
        }
        if !yesterdayGroups.isEmpty {
            buckets.append(("Yesterday", yesterdayGroups))
        }
        if !thisWeekGroups.isEmpty {
            buckets.append(("This Week", thisWeekGroups))
        }
        if !olderGroups.isEmpty {
            buckets.append(("Older", olderGroups))
        }
        return buckets
    }

    private var isEmpty: Bool {
        filteredGroups.isEmpty
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DesignSystemConstants.Padding.standard) {
                    LedgerStaleBanner(familyRecordName: familyRecordName, count: allLedgers.count)
                    balanceHeader
                    if horizontalSizeClass == .regular {
                        HStack(alignment: .top, spacing: 16) {
                            bucketSplitCard
                                .frame(maxWidth: .infinity)
                        }
                    } else {
                        bucketSplitCard
                    }

                    if isEmpty {
                        emptyState
                    } else {
                        ForEach(dateBuckets, id: \.title) { bucket in
                            bucketSection(title: bucket.title, groups: bucket.groups)
                        }
                    }
                }
                .padding(.horizontal, DesignSystemConstants.Padding.standard)
                .padding(.top, DesignSystemConstants.Padding.small)
                .padding(.bottom, DesignSystemConstants.Padding.large)
            }
            .background(Color(DesignSystemConstants.Colors.background).ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                moveMoneyBar
                    .padding(.horizontal, DesignSystemConstants.Padding.standard)
                    .padding(.vertical, DesignSystemConstants.Padding.small)
                    .background(Color(DesignSystemConstants.Colors.background))
            }
            .sheet(isPresented: $isShowingTransfer) {
                BucketTransferView(familyRecordName: familyRecordName, profileRecordName: profileRecordName)
            }
            .sheet(isPresented: $isShowingSplit) {
                // WHY subject scope: split edits the ledger owner's allocation, never the viewer's.
                SavingsSplitView(
                    familyRecordName: familyRecordName,
                    profileRecordName: profileRecordName
                )
            }
            .sheet(item: $selectedGroup) { group in
                LedgerGroupDetailSheet(group: group, selectedBucketFilter: selectedBucketFilter)
            }
            .navigationTitle("MONEY")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                await lifecycleCoordinator?.performManualSync()
            }
        }
        // WHY: view identity tracks profileRecordName so @Query predicates (init-captured) are recreated on profile switch.
        .id(profileRecordName)
    }

    // MARK: - Bucket Split Entry

    private var balanceHeader: some View {
        LedgerBalanceHeaderView(
            totalBalance: totalBalance,
            bucketBalances: bucketBalances,
            selectedBucketFilter: selectedBucketFilter,
            onSelectTotal: { selectedBucketFilter = nil },
            onSelectBucket: { selectedBucketFilter = LedgerBucketFilter.toggled(selectedBucketFilter, with: $0) }
        )
    }

    private var bucketSplitCard: some View {
        BucketSplitEntryRow(accessibilityIdentifier: "ledger.bucketSplitRow") {
            isShowingSplit = true
        }
    }

    // MARK: - Bucket Section

    private func bucketSection(title: String, groups: [TransactionGroup]) -> some View {
        VStack(alignment: .leading, spacing: DesignSystemConstants.Padding.small) {
            SectionHeader(title)

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
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "dollarsign.circle")
                .font(.system(size: 56))
                .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))

            Text(emptyStateTitle)
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)

            Text(
                "No transactions yet — complete your first quest to see earnings here!"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, DesignSystemConstants.Padding.large)

            Spacer()
        }
        .padding(.top, 64)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("ledger.emptyState")
    }

    private var emptyStateTitle: String {
        LedgerEmptyState.title(for: selectedBucketFilter, defaultTitle: "No Transactions Yet")
    }

    // MARK: - Move Money CTA

    private var moveMoneyBar: some View {
        Button {
            HapticsService.lightImpact()
            isShowingTransfer = true
        } label: {
            Label("Move Money", systemImage: "arrow.left.arrow.right")
                .font(.headline)
                // WHY card surface on accent fill: token text keeps contrast in both modes.
                .foregroundStyle(Color(DesignSystemConstants.Colors.cardSurface))
                .frame(maxWidth: .infinity)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.button, style: .continuous)
                        .fill(Color(DesignSystemConstants.Colors.accentBlue))
                )
        }
        .accessibilityHint("Move money between your buckets")
        .accessibilityIdentifier("ledger.moveMoneyButton")
    }
}
