//
//  LedgerEntryCache.swift
//  LootList
//
//  Created for Local-First SwiftData Architecture.
//

import Foundation
import SwiftData

@Model
final class LedgerEntryCache {
    #Index<LedgerEntryCache>([\.familyRecordName], [\.profileRecordName], [\.date])

    @Attribute(.unique) var recordName: String
    var profileRecordName: String
    var familyRecordName: String
    var amount: Double
    var entryDescription: String
    var date: Date
    var source: String

    init(recordName: String,
         profileRecordName: String,
         familyRecordName: String,
         amount: Double,
         entryDescription: String,
         date: Date,
         source: String)
    {
        self.recordName = recordName
        self.profileRecordName = profileRecordName
        self.familyRecordName = familyRecordName
        self.amount = amount
        self.entryDescription = entryDescription
        self.date = date
        self.source = source
    }

    convenience init(from entry: LedgerEntry) {
        self.init(
            recordName: entry.id.recordName,
            profileRecordName: entry.profile.recordID.recordName,
            familyRecordName: entry.family.recordID.recordName,
            amount: entry.amount,
            entryDescription: entry.description,
            date: entry.date,
            source: entry.source
        )
    }
}
