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

    private var goalContributions: [(goal: GoalCache, amount: Double)] {
        PayoutWeekCalculator.goalContributions(for: goals, in: weekBucketEntries)
    }

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

                if !weekBucketEntries.isEmpty {
                    Section("Bucket Split") {
                        ForEach(BucketKind.allCases, id: \.self) { kind in
                            let kindTotal = PayoutWeekCalculator.bucketTotal(for: kind, in: weekBucketEntries)
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
