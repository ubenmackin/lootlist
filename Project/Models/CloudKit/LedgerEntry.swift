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

    /// Serialized CloudKit system fields (metadata, change tag, dates) to avoid
    /// conflict loops when sending updates via CKSyncEngine.
    var encodedSystemFields: Data?

    var profile: CKRecord.Reference

    var amount: Double

    var description: String
    var location: String?
    var date: Date

    /// Free-form movement tag. Allowed values: "manual" (default), "quest" (payout deposits), "interest",
    /// "match", "transfer", plus import-tagged entries ("import-…" prefixed).
    var source: String

    // MARK: - Bucket attribution (V8)

    /// Raw value of `BucketKind` the entry credited; nil for pre-bucket rows
    /// and non-bucketed movements. Kept as a plain string so unknown values
    /// never fail record decoding.
    var bucketKind: String?
    /// Raw value of `BucketKind` money moved OUT of (transfers only).
    var fromBucket: String?
    /// Raw value of `BucketKind` money moved INTO (transfers only).
    var toBucket: String?

    var family: CKRecord.Reference

    init(record: CKRecord) throws {
        guard record.recordType == Self.recordType else {
            throw CKDecodingError.unexpectedRecordType(expected: Self.recordType,
                                                       actual: record.recordType)
        }
        id = record.recordID
        changeTag = record.recordChangeTag
        encodedSystemFields = record.encodedSystemFields

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

        bucketKind = record.extractOptional("bucketKind")
        fromBucket = record.extractOptional("fromBucket")
        toBucket = record.extractOptional("toBucket")

        guard let family = record["family"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("family")
        }
        self.family = family
    }

    func toRecord() -> CKRecord {
        let record = CKRecord.from(systemFields: encodedSystemFields, fallbackType: Self.recordType, fallbackID: id)
        record["profile"] = profile as CKRecordValue
        record["amount"] = amount as CKRecordValue
        record["description"] = description as CKRecordValue
        record["location"] = location as CKRecordValue?
        record["date"] = date as CKRecordValue
        record["source"] = source as CKRecordValue
        record["bucketKind"] = bucketKind as CKRecordValue?
        record["fromBucket"] = fromBucket as CKRecordValue?
        record["toBucket"] = toBucket as CKRecordValue?
        record["family"] = family as CKRecordValue
        return record
    }

    init(profile: CKRecord.Reference,
         amount: Double,
         description: String,
         location: String? = nil,
         date: Date = Date(),
         source: String = "manual",
         bucketKind: String? = nil,
         fromBucket: String? = nil,
         toBucket: String? = nil,
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
        self.bucketKind = bucketKind
        self.fromBucket = fromBucket
        self.toBucket = toBucket
        self.family = family
    }
}
