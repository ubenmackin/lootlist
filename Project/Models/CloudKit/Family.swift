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

    var name: String

    var createdBy: CKRecord.ID

    /// The iCloud user record name of the family's founding user, read from the
    /// server-owned `CKRecord.creatorUserRecordID` on the read path. Anchors
    /// owner-gated mutations (delete, role change, member removal) on CloudKit's
    /// read-only creator identity rather than the forgeable `Profile.role` field.
    /// Not authored locally — `toRecord()` never stamps this field. Nil for
    /// legacy families / records where the creator is unresolved — those fall
    /// back to the legacy parent-role check.
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

        name = try record.extract("name")

        let createdByID: String = try record.extract("createdBy")
        createdBy = CKRecord.ID(recordName: createdByID)

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

        creatorUserRecordName = record.creatorUserRecordID?.recordName
    }

    func toRecord() -> CKRecord {
        let record = CKRecord(recordType: Self.recordType, recordID: id)
        record["name"] = name as CKRecordValue
        record["createdBy"] = createdBy.recordName as CKRecordValue
        record["createdAt"] = createdAt as CKRecordValue
        record["payoutPolicy"] = payoutPolicy.rawValue as CKRecordValue
        record["payoutDay"] = payoutDay.rawValue as CKRecordValue
        return record
    }

    init(name: String,
         createdBy: CKRecord.ID,
         payoutPolicy: PayoutPolicy = .perQuest,
         payoutDay: PayoutDay = .sunday,
         creatorUserRecordName: String? = nil,
         id: CKRecord.ID = CKRecord.ID(recordName: UUID().uuidString))
    {
        self.id = id
        self.name = name
        self.createdBy = createdBy
        createdAt = Date()
        self.payoutPolicy = payoutPolicy
        self.payoutDay = payoutDay
        self.creatorUserRecordName = creatorUserRecordName
    }
}
