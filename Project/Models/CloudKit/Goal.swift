//
//  Goal.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import CloudKit
import Foundation

/// A hero's self-set savings goal. Amounts are stored as integer pennies so
/// goal progress never accumulates floating-point drift; rendering converts to
/// region currency exclusively through `CurrencyFormatter`.
struct Goal: Identifiable, Equatable, Sendable {
    static let recordType: String = "Goal"

    let id: CKRecord.ID

    /// Server-owned CloudKit change tag captured on read for cache-staleness
    /// checks. Not authored locally — `toRecord()` does not stamp this field.
    var changeTag: String?

    /// Serialized CloudKit system fields (metadata, change tag, dates) to avoid
    /// conflict loops when sending updates via CKSyncEngine.
    var encodedSystemFields: Data?

    var profile: CKRecord.Reference
    var family: CKRecord.Reference

    /// Raw value of `BucketKind`; goals fill FIFO inside their own bucket only.
    var bucketKind: String
    var name: String
    /// Free-form grouping label (e.g. "Toys", "Bike"); nil for uncategorized goals.
    var category: String?
    var emojiIcon: String?
    var targetAmountPennies: Int64
    var createdAt: Date
    /// Non-nil marks the goal reached; FIFO filling skips completed goals.
    var completedAt: Date?
    /// Archived goals keep their history but drop out of FIFO cascade ordering.
    var isArchived: Bool

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

        guard let family = record["family"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("family")
        }
        self.family = family

        bucketKind = try record.extract("bucketKind")
        name = try record.extract("name")
        category = record.extractOptional("category")
        emojiIcon = record.extractOptional("emojiIcon")

        // Legacy records predate the Int64 wire field; CloudKit numbers decode
        // as NSNumber, so coerce instead of failing whole-record ingestion.
        if let penniesNumber = record["targetAmountPennies"] as? NSNumber {
            targetAmountPennies = penniesNumber.int64Value
        } else {
            throw CKDecodingError.missingField("targetAmountPennies")
        }

        guard let createdAt = record["createdAt"] as? Date else {
            throw CKDecodingError.missingField("createdAt")
        }
        self.createdAt = createdAt

        completedAt = record["completedAt"] as? Date
        isArchived = record.bool(forKey: "isArchived", default: false)
    }

    func toRecord() -> CKRecord {
        let record = CKRecord.from(systemFields: encodedSystemFields, fallbackType: Self.recordType, fallbackID: id)
        record["profile"] = profile as CKRecordValue
        record["family"] = family as CKRecordValue
        record["bucketKind"] = bucketKind as CKRecordValue
        record["name"] = name as CKRecordValue
        record["category"] = category as CKRecordValue?
        record["emojiIcon"] = emojiIcon as CKRecordValue?
        record["targetAmountPennies"] = targetAmountPennies as CKRecordValue
        record["createdAt"] = createdAt as CKRecordValue
        record["completedAt"] = completedAt as CKRecordValue?
        record["isArchived"] = isArchived as CKRecordValue
        return record
    }

    init(profile: CKRecord.Reference,
         family: CKRecord.Reference,
         bucketKind: BucketKind,
         name: String,
         category: String? = nil,
         emojiIcon: String? = nil,
         targetAmountPennies: Int64,
         createdAt: Date = Date(),
         completedAt: Date? = nil,
         isArchived: Bool = false,
         id: CKRecord.ID = CKRecord.ID(recordName: UUID().uuidString))
    {
        self.id = id
        self.profile = profile
        self.family = family
        self.bucketKind = bucketKind.rawValue
        self.name = name
        self.category = category
        self.emojiIcon = emojiIcon
        self.targetAmountPennies = targetAmountPennies
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.isArchived = isArchived
    }
}

extension Goal: CloudKitRecord {
    static var managedFieldKeys: Set<String> {
        [
            "profile",
            "family",
            "bucketKind",
            "name",
            "category",
            "emojiIcon",
            "targetAmountPennies",
            "createdAt",
            "completedAt",
            "isArchived"
        ]
    }
}
