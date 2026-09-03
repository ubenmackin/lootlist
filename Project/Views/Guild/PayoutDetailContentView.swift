//
//  PayoutDetailContentView.swift
//  LootList
//
//  Created by Ben Mackin on 9/01/26.
//

import SwiftUI

struct PayoutDetailContent: View {
    let period: AllowancePeriodCache
    let heroName: String
    var ledgerEntries: [LedgerEntryCache] = []
    var goals: [GoalCache] = []
    var cachedLedgers: [LedgerEntryCache] = []
    var chartData: [WeeklyEarningPoint] = []
    var aggregatedChartData: [WeeklyEarningPoint]?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var ledgerSortOrder: [KeyPathComparator<LedgerDisplayRow>] = []

    private var weekBucketEntries: [LedgerEntryCache] {
        PayoutWeekCalculator.weekBucketEntries(for: period, from: ledgerEntries)
    }

    private var weekLedgerEntries: [LedgerEntryCache] {
        PayoutWeekCalculator.weekLedgerEntries(for: period, from: cachedLedgers)
    }

    private var goalContributions: [(goal: GoalCache, amount: Double)] {
        PayoutWeekCalculator.goalContributions(for: goals, in: weekBucketEntries)
    }

    private var ledgerRows: [LedgerDisplayRow] {
        weekLedgerEntries.map { entry in
            LedgerDisplayRow(
                id: entry.recordName,
                date: entry.date,
                amount: entry.amount,
                source: entry.source,
                bucket: entry.bucketKind ?? entry.toBucket ?? entry.fromBucket ?? "-",
                entry: entry
            )
        }
    }

    private var sortedLedgerRows: [LedgerDisplayRow] {
        var rows = ledgerRows
        rows.sort(using: ledgerSortOrder)
        // Default to date descending when no explicit sort.
        if ledgerSortOrder.isEmpty {
            rows.sort { $0.date > $1.date }
        }
        return rows
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        summarySection
                        bucketSection
                        goalSection
                        ledgerSection
                    }
                    .padding(.vertical, 12)
                } header: {
                    PayoutChartHeader(data: chartData.isEmpty ? (aggregatedChartData ?? []) : chartData)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(Color(DesignSystemConstants.Colors.background))
                }
            }
            .maxContentWidth()
        }
        .background(Color(DesignSystemConstants.Colors.background))
        .onAppear {
            ledgerSortOrder = [KeyPathComparator(\LedgerDisplayRow.date, order: .reverse)]
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Summary")
                .font(.headline)
                .padding(.horizontal)
            VStack(spacing: 0) {
                detailRow(label: "Hero", value: heroName)
                Divider().padding(.leading, 16)
                detailRow(label: "Week Of", value: period.weekOf.formatted(.dateTime.month().day().year()))
                Divider().padding(.leading, 16)
                detailRow(label: "Status", value: (period.statusEnum ?? .payoutPending).displayName)
                Divider().padding(.leading, 16)
                detailRow(label: "Quests Completed", value: "\(period.questsCompleted) of \(period.questsTotal)")
                Divider().padding(.leading, 16)
                detailRow(label: "Total Earned", value: CurrencyFormatter.string(period.totalEarned))
                if let paidDate = period.paidDate {
                    Divider().padding(.leading, 16)
                    detailRow(label: "Paid Date", value: paidDate.formatted(.dateTime.month().day().year()))
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(DesignSystemConstants.Colors.cardSurface))
            )
            .padding(.horizontal)
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var bucketSection: some View {
        if !weekBucketEntries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Bucket Split")
                    .font(.headline)
                    .padding(.horizontal)
                VStack(spacing: 0) {
                    ForEach(BucketKind.allCases, id: \.self) { kind in
                        let kindTotal = PayoutWeekCalculator.bucketTotal(for: kind, in: weekBucketEntries)
                        if kindTotal != 0 {
                            HStack {
                                Label(kind.displayName, systemImage: kind.iconSystemName)
                                    .font(.subheadline)
                                Spacer()
                                Text(CurrencyFormatter.string(kindTotal))
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            Divider().padding(.leading, 16)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(DesignSystemConstants.Colors.cardSurface))
                )
                .padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private var goalSection: some View {
        if !goalContributions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Goal Contributions")
                    .font(.headline)
                    .padding(.horizontal)
                VStack(spacing: 0) {
                    ForEach(goalContributions, id: \.goal.recordName) { item in
                        HStack {
                            Text(item.goal.name)
                                .font(.subheadline)
                            Spacer()
                            Text(CurrencyFormatter.string(item.amount))
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        Divider().padding(.leading, 16)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(DesignSystemConstants.Colors.cardSurface))
                )
                .padding(.horizontal)
            }
        }
    }

    private var ledgerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ledger Entries")
                .font(.headline)
                .padding(.horizontal)
            if weekLedgerEntries.isEmpty {
                Text("No ledger entries for this week.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(DesignSystemConstants.Colors.cardSurface))
                    )
                    .padding(.horizontal)
                // WHY: Table on regular gives sortable columns; compact falls back to card rows for narrow 50/50 where Table would clip.
            } else if horizontalSizeClass == .regular {
                ledgerTable
                    .padding(.horizontal)
            } else {
                VStack(spacing: 0) {
                    ForEach(sortedLedgerRows) { row in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.date, format: .dateTime.month().day().year())
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                Text(row.source)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(CurrencyFormatter.string(row.amount))
                                    .font(.caption.weight(.bold).monospacedDigit())
                                Text(row.bucket)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        Divider().padding(.leading, 16)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(DesignSystemConstants.Colors.cardSurface))
                )
                .padding(.horizontal)
            }
        }
    }

    private var ledgerTable: some View {
        Table(sortedLedgerRows, sortOrder: $ledgerSortOrder) {
            TableColumn("Date", value: \.date) { row in
                Text(row.date, format: .dateTime.month().day().year())
                    .font(.caption.monospacedDigit())
            }
            TableColumn("Amount", value: \.amount) { row in
                Text(CurrencyFormatter.string(row.amount))
                    .font(.caption.monospacedDigit())
                    .monospacedDigit()
            }
            TableColumn("Source", value: \.source) { row in
                Text(row.source)
                    .font(.caption)
            }
            TableColumn("Bucket", value: \.bucket) { row in
                Text(row.bucket)
                    .font(.caption)
            }
        }
        .frame(minHeight: 180, maxHeight: 320)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(DesignSystemConstants.Colors.cardSurface))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct LedgerDisplayRow: Identifiable {
    let id: String
    let date: Date
    let amount: Double
    let source: String
    let bucket: String
    let entry: LedgerEntryCache
}
