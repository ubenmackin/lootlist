//
//  NotificationPreference.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation

struct NotificationPreference: Identifiable, Equatable, Sendable {
    static let recordType: String = "NotificationPreference"

    let id: CKRecord.ID

    /// Server-owned CloudKit change tag captured on read for cache-staleness
    /// checks. Not authored locally — `toRecord()` does not stamp this field.
    var changeTag: String?

    var profile: CKRecord.Reference

    var eventType: NotificationEventType

    var enabled: Bool

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

        guard let eventTypeRaw: String = record.extractOptional("eventType"),
              let eventType = NotificationEventType(rawValue: eventTypeRaw)
        else {
            throw CKDecodingError.missingField("eventType")
        }
        self.eventType = eventType

        enabled = record.bool(forKey: "enabled", default: false)

        guard let family = record["family"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("family")
        }
        self.family = family
    }

    func toRecord() -> CKRecord {
        let record = CKRecord(recordType: Self.recordType, recordID: id)
        record["profile"] = profile as CKRecordValue
        record["eventType"] = eventType.rawValue as CKRecordValue
        record["enabled"] = enabled as CKRecordValue
        record["family"] = family as CKRecordValue
        return record
    }

    init(profile: CKRecord.Reference,
         eventType: NotificationEventType,
         enabled: Bool,
         family: CKRecord.Reference,
         id: CKRecord.ID = CKRecord.ID(recordName: UUID().uuidString))
    {
        self.id = id
        self.profile = profile
        self.eventType = eventType
        self.enabled = enabled
        self.family = family
    }

    init(profile: CKRecord.Reference,
         eventType: NotificationEventType,
         role: UserRole,
         family: CKRecord.Reference,
         id: CKRecord.ID = CKRecord.ID(recordName: UUID().uuidString))
    {
        let defaultEnabled = role.isParent
            ? eventType.defaultEnabledForParent
            : eventType.defaultEnabledForHero
        self.init(profile: profile,
                  eventType: eventType,
                  enabled: defaultEnabled,
                  family: family,
                  id: id)
    }
}
