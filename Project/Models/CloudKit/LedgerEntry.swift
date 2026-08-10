//
//  LedgerEntry.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation

struct LedgerEntry: Identifiable, Equatable, Sendable {
    static let recordType: String = "LedgerEntry"

    let id: CKRecord.ID

    /// Server-owned CloudKit change tag captured on read for cache-staleness
    /// checks. Not authored locally — `toRecord()` does not stamp this field.
    var changeTag: String?

    var profile: CKRecord.Reference

    var amount: Double

    var description: String
    var location: String?
    var date: Date

    var source: String

    var family: CKRecord.Reference

    init(record: CKRecord) throws {
        guard record.recordType == Self.recordType else {
            throw CKDecodingError.unexpectedRecordType(expected: Self.recordType,
                                                       actual: record.recordType)
        }
        id = record.recordID
        changeTag = record.recordChangeTag

        guard let profile = record["profile"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("profile")
        }
        self.profile = profile

        amount = try record.extract("amount")
        description = try record.extract("description")
        location = record["location"] as? String

        guard let date = record["date"] as? Date else {
            throw CKDecodingError.missingField("date")
        }
        self.date = date

        source = try record.extract("source")

        guard let family = record["family"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("family")
        }
        self.family = family
    }

    func toRecord() -> CKRecord {
        let record = CKRecord(recordType: Self.recordType, recordID: id)
        record["profile"] = profile as CKRecordValue
        record["amount"] = amount as CKRecordValue
        record["description"] = description as CKRecordValue
        record["location"] = location as CKRecordValue?
        record["date"] = date as CKRecordValue
        record["source"] = source as CKRecordValue
        record["family"] = family as CKRecordValue
        return record
    }

    init(profile: CKRecord.Reference,
         amount: Double,
         description: String,
         location: String? = nil,
         date: Date = Date(),
         source: String = "manual",
         family: CKRecord.Reference,
         id: CKRecord.ID = CKRecord.ID(recordName: UUID().uuidString))
    {
        self.id = id
        self.profile = profile
        self.amount = amount
        self.description = description
        self.location = location
        self.date = date
        self.source = source
        self.family = family
    }
}
