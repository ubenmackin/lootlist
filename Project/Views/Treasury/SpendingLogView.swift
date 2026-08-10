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

    @Query private var cachedLedgers: [LedgerEntryCache]

    @State private var showAllTime: Bool = false

    init(viewModel: TreasuryViewModel, familyRecordName: String? = nil) {
        self.viewModel = viewModel
        self.familyRecordName = familyRecordName

        // Filter queries by family at the SwiftData store layer. When familyRecordName is nil,
        // scope to an empty string ("") so zero rows are returned rather than fetching unscoped across all families.
        let targetFamily = familyRecordName ?? ""
        let ledgerFilter = #Predicate<LedgerEntryCache> { $0.familyRecordName == targetFamily }
        _cachedLedgers = Query(
            filter: ledgerFilter,
            sort: \LedgerEntryCache.date,
            order: .reverse
        )
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                LedgerDateRangeMenu(showAllTime: $showAllTime)
            }
        }
        .onChange(of: showAllTime) { _, newValue in
            viewModel.rebuildSpendingLog(from: cachedLedgers, showAllTime: newValue)
        }
        .onChange(of: cachedLedgers) { _, newLedgers in
            viewModel.rebuildSpendingLog(from: newLedgers, showAllTime: showAllTime)
        }
        .task {
            viewModel.rebuildSpendingLog(from: cachedLedgers, showAllTime: showAllTime)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "scroll.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Empty Ledger")
                .font(.headline)
            Text(showAllTime
                ? "No entries yet."
                : "No ledger activity this week.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding(.top, 64)
    }
}

struct LedgerEntryRow: View {
    let entry: SpendingLogRow

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .top, spacing: 12) {
                let iconInfo = LedgerRowStyle.sourceIcon(for: entry.source, fallbackTint: entry.amount >= 0 ? .gold : .red)
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
                    HStack {
                        Text(LedgerRowStyle.sourceLabel(for: entry.source))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(iconInfo.color)
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
                    .foregroundStyle(entry.amount >= 0 ? Color.gold : .red)
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
