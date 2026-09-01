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
    let familyRecordName: String?
    private let profileRecordName: String?

    @Binding var scope: CalendarScope

    @Query private var cachedLedgers: [LedgerEntryCache]

    init(viewModel: TreasuryViewModel, familyRecordName: String? = nil, profileRecordName: String? = nil, scope: Binding<CalendarScope>) {
        self.viewModel = viewModel
        self.familyRecordName = familyRecordName
        self.profileRecordName = profileRecordName
        _scope = scope
        let targetFamily = familyRecordName ?? ""
        let targetProfile = profileRecordName ?? ""
        let ledgerFilter = #Predicate<LedgerEntryCache> { $0.familyRecordName == targetFamily && $0.profileRecordName == targetProfile }
        _cachedLedgers = Query(
            filter: ledgerFilter,
            sort: \LedgerEntryCache.date,
            order: .reverse
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                CalendarScopeFilterView(scope: $scope)
                    .padding(.horizontal)

                if viewModel.spendingLog.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.spendingLog) { entry in
                            LedgerEntryRow(entry: entry)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Scroll of Spending")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: scope) { _, newScope in
            viewModel.rebuildSpendingLog(from: cachedLedgers, scope: newScope)
        }
        .onChange(of: cachedLedgers) { _, newLedgers in
            viewModel.rebuildSpendingLog(from: newLedgers, scope: scope)
        }
        .task {
            viewModel.rebuildSpendingLog(from: cachedLedgers, scope: scope)
        }
    }

    private var emptyState: some View {
        EmptyStateView(
            systemImage: "scroll.fill",
            title: "Empty Ledger",
            description: scope.emptyStateCopy,
            topPadding: 64
        )
    }
}

struct LedgerEntryRow: View {
    let entry: SpendingLogRow

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .top, spacing: 12) {
                let iconInfo = LedgerRowStyle.sourceIcon(for: entry.source, fallbackTint: entry.amount >= 0 ? .gold : Color(DesignSystemConstants.Colors.dangerRed))
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.description), \(GoldFormat.signed(entry.amount)), \(LedgerRowStyle.dateText(for: entry.date))")
    }
}
