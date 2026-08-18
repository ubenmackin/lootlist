//
//  RewardEvent.swift
//  LootList
//
//  Created by Ben Mackin on 8/1/26.
//

import CloudKit
import Foundation

/// Immutable record of an XP / gold reward granted for completing a quest.
/// Provides server-authoritative idempotency: deterministic ID `reward-{completionID}`
/// is claimed with an atomic create-if-absent operation before XP is credited.
struct RewardEvent: Identifiable, Equatable, Sendable, CloudKitRecord {
    static let recordType: String = "RewardEvent"

    let id: CKRecord.ID
    var changeTag: String?
    var encodedSystemFields: Data?

    var profile: CKRecord.Reference
    var questCompletion: CKRecord.Reference
    var xpAmount: Int
    var goldAmount: Double
    var timestamp: Date
    var family: CKRecord.Reference

    init(
        profile: CKRecord.Reference,
        questCompletion: CKRecord.Reference,
        xpAmount: Int,
        goldAmount: Double,
        timestamp: Date = Date(),
        family: CKRecord.Reference,
        id: CKRecord.ID
    ) {
        self.id = id
        self.profile = profile
        self.questCompletion = questCompletion
        self.xpAmount = xpAmount
        self.goldAmount = goldAmount
        self.timestamp = timestamp
        self.family = family
    }

    init(record: CKRecord) throws {
        guard record.recordType == Self.recordType else {
            throw CKDecodingError.unexpectedRecordType(
                expected: Self.recordType,
                actual: record.recordType
            )
        }
        id = record.recordID
        changeTag = record.recordChangeTag
        encodedSystemFields = record.encodedSystemFields

        guard let profile = record["profile"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("profile")
        }
        self.profile = profile

        guard let questCompletion = record["questCompletion"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("questCompletion")
        }
        self.questCompletion = questCompletion

        xpAmount = record.extractOptional("xpAmount") ?? 0
        goldAmount = record.extractOptional("goldAmount") ?? 0.0

        guard let timestamp = record["timestamp"] as? Date else {
            throw CKDecodingError.missingField("timestamp")
        }
        self.timestamp = timestamp

        guard let family = record["family"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("family")
        }
        self.family = family
    }

    func toRecord() -> CKRecord {
        let record = CKRecord.from(systemFields: encodedSystemFields, fallbackType: Self.recordType, fallbackID: id)
        record["profile"] = profile as CKRecordValue
        record["questCompletion"] = questCompletion as CKRecordValue
        record["xpAmount"] = xpAmount as CKRecordValue
        record["goldAmount"] = goldAmount as CKRecordValue
        record["timestamp"] = timestamp as CKRecordValue
        record["family"] = family as CKRecordValue
        return record
    }

    static func recordID(completionRecordName: String, zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: "reward-\(completionRecordName)", zoneID: zoneID)
    }
}
