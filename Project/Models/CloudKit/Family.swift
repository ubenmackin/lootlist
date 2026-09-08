//
//  Family.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation

struct Family: Identifiable, Equatable, Sendable {
    static let recordType: String = "Family"

    let id: CKRecord.ID

    /// Server-owned CloudKit change tag captured on read for cache-staleness
    /// checks. Not authored locally — `toRecord()` does not stamp this field.
    var changeTag: String?

    /// Serialized CloudKit system fields (metadata, change tag, dates) to avoid
    /// conflict loops when sending updates via CKSyncEngine.
    var encodedSystemFields: Data?

    var name: String

    /// The iCloud user record name of the family's founding user, read from the server-owned
    /// `CKRecord.creatorUserRecordID` on the read path.
    var creatorUserRecordName: String?

    var createdAt: Date

    var payoutPolicy: PayoutPolicy

    var payoutDay: PayoutDay

    init(record: CKRecord) throws {
        guard record.recordType == Self.recordType else {
            throw CKDecodingError.unexpectedRecordType(expected: Self.recordType,
                                                       actual: record.recordType)
        }
        id = record.recordID
        changeTag = record.recordChangeTag
        encodedSystemFields = record.encodedSystemFields

        name = try record.extract("name")

        // WHY deny-by-default: unresolved stamp denies; legacy field never becomes anchor.
        creatorUserRecordName = record.creatorUserRecordID?.recordName

        guard let createdAt = record["createdAt"] as? Date else {
            throw CKDecodingError.missingField("createdAt")
        }
        self.createdAt = createdAt

        if let rawPolicy: String = record.extractOptional("payoutPolicy"),
           let policy = PayoutPolicy(rawValue: rawPolicy)
        {
            payoutPolicy = policy
        } else {
            payoutPolicy = .perQuest
        }

        if let rawDay: String = record.extractOptional("payoutDay"),
           let day = PayoutDay(rawValue: rawDay)
        {
            payoutDay = day
        } else {
            payoutDay = .sunday
        }
    }

    func toRecord() -> CKRecord {
        let record = CKRecord.from(systemFields: encodedSystemFields, fallbackType: Self.recordType, fallbackID: id)
        record["name"] = name as CKRecordValue
        // WHY server stamps creator: decoded only on read path, never authored locally.
        record["createdAt"] = createdAt as CKRecordValue
        record["payoutPolicy"] = payoutPolicy.rawValue as CKRecordValue
        record["payoutDay"] = payoutDay.rawValue as CKRecordValue
        return record
    }

    init(name: String,
         creatorUserRecordName: String? = nil,
         createdAt: Date = Date(),
         payoutPolicy: PayoutPolicy = .perQuest,
         payoutDay: PayoutDay = .sunday,
         id: CKRecord.ID = CKRecord.ID(recordName: UUID().uuidString))
    {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.payoutPolicy = payoutPolicy
        self.payoutDay = payoutDay
        self.creatorUserRecordName = creatorUserRecordName
    }
}
