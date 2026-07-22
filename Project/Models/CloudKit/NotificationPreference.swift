import Foundation
import CloudKit

struct NotificationPreference: Identifiable, Equatable, Sendable {

    static let recordType: String = "NotificationPreference"

    let id: CKRecord.ID

    var profile: CKRecord.Reference

    var eventType: NotificationEventType

    var enabled: Bool

    var pushEnabled: Bool

    var family: CKRecord.Reference

    init(record: CKRecord) throws {
        guard record.recordType == Self.recordType else {
            throw CKDecodingError.unexpectedRecordType(expected: Self.recordType,
                                                        actual: record.recordType)
        }
        self.id = record.recordID

        guard let profile = record["profile"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("profile")
        }
        self.profile = profile

        guard let eventTypeRaw = record["eventType"] as? String,
              let eventType = NotificationEventType(rawValue: eventTypeRaw) else {
            throw CKDecodingError.missingField("eventType")
        }
        self.eventType = eventType

        self.enabled     = (record["enabled"]     as? Bool) ?? false
        self.pushEnabled = (record["pushEnabled"] as? Bool) ?? false

        guard let family = record["family"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("family")
        }
        self.family = family
    }

    func toRecord() -> CKRecord {
        let record = CKRecord(recordType: Self.recordType, recordID: id)
        record["profile"]      = profile as CKRecordValue
        record["eventType"]   = eventType.rawValue as CKRecordValue
        record["enabled"]      = enabled as CKRecordValue
        record["pushEnabled"]  = pushEnabled as CKRecordValue
        record["family"]       = family as CKRecordValue
        return record
    }

    init(profile: CKRecord.Reference,
         eventType: NotificationEventType,
         enabled: Bool,
         pushEnabled: Bool,
         family: CKRecord.Reference,
         id: CKRecord.ID = CKRecord.ID(recordName: UUID().uuidString)) {
        self.id = id
        self.profile = profile
        self.eventType = eventType
        self.enabled = enabled
        self.pushEnabled = pushEnabled
        self.family = family
    }

    init(profile: CKRecord.Reference,
         eventType: NotificationEventType,
         role: UserRole,
         family: CKRecord.Reference,
         id: CKRecord.ID = CKRecord.ID(recordName: UUID().uuidString)) {
        let defaultEnabled = role.isParent
            ? eventType.defaultEnabledForParent
            : eventType.defaultEnabledForHero
        self.init(profile: profile,
                  eventType: eventType,
                  enabled: defaultEnabled,
                  pushEnabled: defaultEnabled,
                  family: family,
                  id: id)
    }
}
