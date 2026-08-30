//
//  LedgerRowFactory.swift
//  LootList
//
//  Created by Ben Mackin on 8/29/26.
//

import Foundation

// WHY: Single cache→row path (profile filter + CalendarScope bucket filter + sorted mapping) so Treasury/HeroLedger share one row factory instead of duplicating rebuild logic.
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
