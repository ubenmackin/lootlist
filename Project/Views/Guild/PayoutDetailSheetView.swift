//
//  PayoutDetailSheetView.swift
//  LootList
//
//  Created by Ben Mackin on 9/01/26.
//

import SwiftUI

struct PayoutDetailSheet: View {
    let period: AllowancePeriodCache
    let heroName: String
    var ledgerEntries: [LedgerEntryCache] = []
    var goals: [GoalCache] = []
    @Environment(\.dismiss) private var dismiss

    private var weekBucketEntries: [LedgerEntryCache] {
        PayoutWeekCalculator.weekBucketEntries(for: period, from: ledgerEntries)
    }

    private var payoutLinkedEntries: [LedgerEntryCache] {
        PayoutWeekCalculator.payoutLinkedEntries(for: period, from: ledgerEntries)
    }

    private var weekLedgerEntries: [LedgerEntryCache] {
        PayoutWeekCalculator.weekLedgerEntries(for: period, from: ledgerEntries)
            .filter { BucketService.isLedgerVisible($0) }
    }

    private var goalContributions: [(goal: GoalCache, amount: Int64)] {
        // WHY week-wide goals: Bucket Split shows the payout-linked split only, while goal fills ride week-wide contrib records including real-time settlements.
        PayoutWeekCalculator.goalContributions(for: goals, in: weekBucketEntries)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Summary") {
                    LabeledContent("Hero", value: heroName)
                    LabeledContent("Week Of", value: period.weekOf.formatted(.dateTime.month().day().year()))
                    LabeledContent(
                        "Status",
                        value: (period.statusEnum ?? .payoutPending).displayName
                    )
                    LabeledContent(
                        "Quests Completed",
                        value: period.questsTotal == 0
                            ? "\(period.questsCompleted) completed"
                            : "\(period.questsCompleted) of \(period.questsTotal)"
                    )
                    LabeledContent("Total Earned", value: CurrencyFormatter.string(period.totalEarned))
                    if let paidDate = period.paidDate {
                        LabeledContent("Paid Date", value: paidDate.formatted(.dateTime.month().day().year()))
                    }
                }

                if !payoutLinkedEntries.isEmpty {
                    Section("Bucket Split") {
                        ForEach(BucketKind.allCases, id: \.self) { kind in
                            let kindTotal = PayoutWeekCalculator.bucketTotal(for: kind, in: payoutLinkedEntries)
                            if kindTotal != 0 {
                                LabeledContent(kind.displayName, value: CurrencyFormatter.string(kindTotal))
                            }
                        }
                    }
                }

                if !goalContributions.isEmpty {
                    Section("Goal Contributions") {
                        ForEach(goalContributions, id: \.goal.recordName) { item in
                            LabeledContent(item.goal.name, value: CurrencyFormatter.string(item.amount))
                        }
                    }
                }

                Section("Ledger Entries") {
                    if weekLedgerEntries.isEmpty {
                        Text("No ledger entries for this week.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(weekLedgerEntries, id: \.recordName) { entry in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(entry.date, format: .dateTime.month().day().year())
                                        .font(.subheadline)
                                    Text(entry.source)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(CurrencyFormatter.string(entry.amount))
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                            }
                        }
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
