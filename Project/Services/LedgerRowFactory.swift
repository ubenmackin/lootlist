//
//  LedgerRowFactory.swift
//  LootList
//
//  Created by Ben Mackin on 8/29/26.
//

import Foundation

/// Factory mapping cached ledger entries to presentation spending rows.
enum LedgerRowFactory {
    static func spendingRows(from ledgers: [LedgerEntryCache], profileRecordName: String, scope: CalendarScope, payoutDay: PayoutDay) -> [SpendingLogRow] {
        ledgers
            .filter { $0.profileRecordName == profileRecordName }
            .filter { scope.contains($0.date, payoutDay: payoutDay) }
            .map { ledger in
                SpendingLogRow(
                    id: ledger.recordName,
                    amount: ledger.amount,
                    description: ledger.entryDescription,
                    location: ledger.location,
                    date: ledger.date,
                    source: ledger.source,
                    rawCache: ledger
                )
            }
            .sorted { $0.date > $1.date }
    }
}
