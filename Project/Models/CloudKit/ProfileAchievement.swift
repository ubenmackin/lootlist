//
//  ProfileAchievement.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation

struct ProfileAchievement: Identifiable, Equatable, Sendable {
    static let recordType: String = "ProfileAchievement"

    let id: CKRecord.ID

    /// Server-owned CloudKit change tag captured on read for cache-staleness
    /// checks. Not authored locally — `toRecord()` does not stamp this field.
    var changeTag: String?

    /// Serialized CloudKit system fields (metadata, change tag, dates) to avoid
    /// conflict loops when sending updates via CKSyncEngine.
    var encodedSystemFields: Data?

    var achievement: CKRecord.Reference

    var profile: CKRecord.Reference

    var earnedDate: Date

    var family: CKRecord.Reference

    /// Generates a deterministic record ID for a profile's achievement trophy,
    /// ensuring concurrent awards on different devices merge into the exact same record.
    static func recordID(profileID: CKRecord.ID, achievementID: CKRecord.ID, zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: "\(profileID.recordName)_\(achievementID.recordName)", zoneID: zoneID)
    }

    init(id: CKRecord.ID, achievement: CKRecord.Reference, profile: CKRecord.Reference, earnedDate: Date, family: CKRecord.Reference) {
        self.id = id
        self.achievement = achievement
        self.profile = profile
        self.earnedDate = earnedDate
        self.family = family
    }

    init(record: CKRecord) throws {
        guard record.recordType == Self.recordType else {
            throw CKDecodingError.unexpectedRecordType(expected: Self.recordType,
                                                       actual: record.recordType)
        }
        id = record.recordID
        changeTag = record.recordChangeTag
        encodedSystemFields = record.encodedSystemFields

        guard let achievement = record["achievement"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("achievement")
        }
        self.achievement = achievement

        guard let profile = record["profile"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("profile")
        }
        self.profile = profile

        guard let earnedDate = record["earnedDate"] as? Date else {
            throw CKDecodingError.missingField("earnedDate")
        }
        self.earnedDate = earnedDate

        guard let family = record["family"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("family")
        }
        self.family = family
    }

    func toRecord() -> CKRecord {
        let record = CKRecord.from(systemFields: encodedSystemFields, fallbackType: Self.recordType, fallbackID: id)
        record["achievement"] = achievement as CKRecordValue
        record["profile"] = profile as CKRecordValue
        record["earnedDate"] = earnedDate as CKRecordValue
        record["family"] = family as CKRecordValue
        return record
    }

    init(achievement: CKRecord.Reference,
         profile: CKRecord.Reference,
         earnedDate: Date = Date(),
         family: CKRecord.Reference,
         id: CKRecord.ID? = nil)
    {
        let resolvedID = id ?? Self.recordID(
            profileID: profile.recordID,
            achievementID: achievement.recordID,
            zoneID: profile.recordID.zoneID
        )
        self.id = resolvedID
        self.achievement = achievement
        self.profile = profile
        self.earnedDate = earnedDate
        self.family = family
    }
}
