//
//  Profile.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation

struct Profile: Identifiable, Equatable, Sendable {
    static let recordType: String = "Profile"

    let id: CKRecord.ID

    /// Server-owned CloudKit change tag captured on read for cache-staleness
    /// checks. Not authored locally — `toRecord()` does not stamp this field.
    var changeTag: String?

    var displayName: String
    var avatarClass: AvatarClass?
    var avatarPresetID: String?
    var customAvatarImageData: Data?
    var role: UserRole
    var xp: Int
    var level: Int

    var iCloudUserID: CKRecord.ID

    var family: CKRecord.Reference

    var isActive: Bool
    var payoutPolicy: PayoutPolicy
    var payoutDay: PayoutDay?

    var effectiveClassDisplay: String {
        if let avatarClass {
            avatarClass.displayName
        } else {
            role.genericRoleName
        }
    }

    init(record: CKRecord) throws {
        guard record.recordType == Self.recordType else {
            throw CKDecodingError.unexpectedRecordType(expected: Self.recordType,
                                                       actual: record.recordType)
        }
        id = record.recordID
        changeTag = record.recordChangeTag

        displayName = try record.extract("displayName")

        if let avatarClassRaw: String = record.extractOptional("avatarClass") {
            avatarClass = AvatarClass(rawValue: avatarClassRaw)
        } else {
            avatarClass = nil
        }

        avatarPresetID = record.extractOptional("avatarPresetID")
        customAvatarImageData = record.extractOptional("customAvatarImageData")

        guard let roleRaw: String = record.extractOptional("role"),
              let role = UserRole(rawValue: roleRaw)
        else {
            throw CKDecodingError.missingField("role")
        }
        self.role = role

        xp = try record.extract("xp")
        level = try record.extract("level")

        let iCloudUserIDStr: String = try record.extract("iCloudUserID")
        iCloudUserID = CKRecord.ID(recordName: iCloudUserIDStr)

        guard let familyRef = record["family"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("family")
        }
        family = familyRef

        isActive = record.bool(forKey: "isActive", default: false)

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
            payoutDay = nil
        }
    }

    func toRecord() -> CKRecord {
        let record = CKRecord(recordType: Self.recordType, recordID: id)
        record["displayName"] = displayName as CKRecordValue
        if let avatarClass {
            record["avatarClass"] = avatarClass.rawValue as CKRecordValue
        } else {
            record["avatarClass"] = nil
        }
        if let avatarPresetID {
            record["avatarPresetID"] = avatarPresetID as CKRecordValue
        } else {
            record["avatarPresetID"] = nil
        }
        if let customAvatarImageData {
            record["customAvatarImageData"] = customAvatarImageData as CKRecordValue
        } else {
            record["customAvatarImageData"] = nil
        }
        record["role"] = role.rawValue as CKRecordValue
        record["xp"] = xp as CKRecordValue
        record["level"] = level as CKRecordValue
        record["iCloudUserID"] = iCloudUserID.recordName as CKRecordValue
        record["family"] = family as CKRecordValue
        record["isActive"] = isActive as CKRecordValue
        record["payoutPolicy"] = payoutPolicy.rawValue as CKRecordValue
        if let payoutDay {
            record["payoutDay"] = payoutDay.rawValue as CKRecordValue
        } else {
            record["payoutDay"] = nil
        }
        return record
    }

    init(displayName: String,
         avatarClass: AvatarClass? = nil,
         avatarPresetID: String? = nil,
         customAvatarImageData: Data? = nil,
         role: UserRole,
         iCloudUserID: CKRecord.ID,
         family: CKRecord.Reference,
         payoutPolicy: PayoutPolicy = .perQuest,
         payoutDay: PayoutDay? = nil,
         id: CKRecord.ID = CKRecord.ID(recordName: UUID().uuidString))
    {
        self.id = id
        self.displayName = displayName
        self.avatarClass = avatarClass
        self.avatarPresetID = avatarPresetID
        self.customAvatarImageData = customAvatarImageData
        self.role = role
        xp = 0
        level = 1
        self.iCloudUserID = iCloudUserID
        self.family = family
        isActive = true
        self.payoutPolicy = payoutPolicy
        self.payoutDay = payoutDay
    }
}

extension Profile: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
