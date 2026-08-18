//
//  GemLedger.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import CloudKit
import Foundation

struct GemLedger: CloudKitRecord, Identifiable, Equatable, Sendable {
    static let recordType: String = "GemLedger"

    static func deterministicRecordID(
        profileRecordName: String,
        eventKey: String,
        source: String,
        zoneID: CKRecordZone.ID
    ) -> CKRecord.ID {
        CKRecord.ID(
            recordName: "gem-\(profileRecordName)-\(eventKey)-\(source)",
            zoneID: zoneID
        )
    }

    static func purchaseRecordID(
        profileRecordName: String,
        itemID: String,
        eventKey: String?,
        zoneID: CKRecordZone.ID
    ) -> CKRecord.ID {
        deterministicRecordID(
            profileRecordName: profileRecordName,
            eventKey: eventKey ?? "purchase-\(itemID)",
            source: "shopPurchase",
            zoneID: zoneID
        )
    }

    let id: CKRecord.ID

    /// Server-owned CloudKit change tag captured on read for cache-staleness
    /// checks. Not authored locally — `toRecord()` does not stamp this field.
    var changeTag: String?

    /// Serialized CloudKit system fields (metadata, change tag, dates) to avoid
    /// conflict loops when sending updates via CKSyncEngine.
    var encodedSystemFields: Data?

    var profileRecordName: String
    var family: CKRecord.Reference
    var amount: Int
    var source: String
    var sourceDetail: String?
    var createdAt: Date

    init(record: CKRecord) throws {
        guard record.recordType == Self.recordType else {
            throw CKDecodingError.unexpectedRecordType(expected: Self.recordType,
                                                       actual: record.recordType)
        }
        id = record.recordID
        changeTag = record.recordChangeTag
        encodedSystemFields = record.encodedSystemFields

        profileRecordName = try record.extract("profileRecordName")

        guard let family = record["family"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("family")
        }
        self.family = family

        amount = try record.extract("amount")
        source = try record.extract("source")
        sourceDetail = record["sourceDetail"] as? String

        guard let createdAt = record["createdAt"] as? Date else {
            throw CKDecodingError.missingField("createdAt")
        }
        self.createdAt = createdAt
    }

    func toRecord() -> CKRecord {
        let record = CKRecord.from(systemFields: encodedSystemFields, fallbackType: Self.recordType, fallbackID: id)
        record["profileRecordName"] = profileRecordName as CKRecordValue
        record["family"] = family as CKRecordValue
        record["amount"] = amount as CKRecordValue
        record["source"] = source as CKRecordValue
        record["sourceDetail"] = sourceDetail as CKRecordValue?
        record["createdAt"] = createdAt as CKRecordValue
        return record
    }

    init(profileRecordName: String,
         family: CKRecord.Reference,
         amount: Int,
         source: String,
         sourceDetail: String? = nil,
         createdAt: Date = Date(),
         id: CKRecord.ID = CKRecord.ID(recordName: UUID().uuidString))
    {
        self.id = id
        self.profileRecordName = profileRecordName
        self.family = family
        self.amount = amount
        self.source = source
        self.sourceDetail = sourceDetail
        self.createdAt = createdAt
    }
}

extension GemLedger {
    static var managedFieldKeys: Set<String> {
        [
            "profileRecordName",
            "family",
            "amount",
            "source",
            "sourceDetail",
            "createdAt"
        ]
    }
}

extension GemLedger: CacheMergeableDomain {}
