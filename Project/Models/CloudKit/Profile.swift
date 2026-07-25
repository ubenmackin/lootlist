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

        guard let displayName = record["displayName"] as? String else {
            throw CKDecodingError.missingField("displayName")
        }
        self.displayName = displayName

        if let avatarClassRaw = record["avatarClass"] as? String {
            avatarClass = AvatarClass(rawValue: avatarClassRaw)
        } else {
            avatarClass = nil
        }

        avatarPresetID = record["avatarPresetID"] as? String
        customAvatarImageData = record["customAvatarImageData"] as? Data

        guard let roleRaw = record["role"] as? String,
              let role = UserRole(rawValue: roleRaw)
        else {
            throw CKDecodingError.missingField("role")
        }
        self.role = role

        guard let xp = record["xp"] as? Int else {
            throw CKDecodingError.missingField("xp")
        }
        self.xp = xp

        guard let level = record["level"] as? Int else {
            throw CKDecodingError.missingField("level")
        }
        self.level = level

        guard let iCloudUserIDStr = record["iCloudUserID"] as? String else {
            throw CKDecodingError.missingField("iCloudUserID")
        }
        iCloudUserID = CKRecord.ID(recordName: iCloudUserIDStr)

        guard let familyRef = record["family"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("family")
        }
        family = familyRef

        isActive = (record["isActive"] as? Bool) ?? false

        if let rawPolicy = record["payoutPolicy"] as? String,
           let policy = PayoutPolicy(rawValue: rawPolicy)
        {
            payoutPolicy = policy
        } else {
            payoutPolicy = .perQuest
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
    }
}

extension Profile: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
