//
//  CloudKitRecord.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation

protocol CloudKitRecord: Sendable, Identifiable {
    static var recordType: String { get }
    static var managedFieldKeys: Set<String> { get }

    init(record: CKRecord) throws

    func toRecord() -> CKRecord
}

extension CloudKitRecord {
    static var managedFieldKeys: Set<String> {
        []
    }
}

extension CKRecord {
    func bool(forKey key: String, default defaultValue: Bool = false) -> Bool {
        if let boolVal = self[key] as? Bool {
            return boolVal
        }
        if let numVal = self[key] as? NSNumber {
            return numVal.boolValue
        }
        return defaultValue
    }

    /// WHY NSNumber inspection: legacy rows store dollars as Double while
    /// migrated rows store pennies as Int64 under the same key; objCType
    /// distinguishes them so $5.00 never decodes as 5 pennies.
    func pennies(forKey key: String) throws -> Int64 {
        guard let raw = self[key] else {
            throw CKDecodingError.missingField(key)
        }
        if let number = raw as? NSNumber {
            let objCType = String(cString: number.objCType)
            if objCType == "d" || objCType == "f" {
                return CurrencyFormatter.dollarsToPennies(number.doubleValue)
            }
            return number.int64Value
        }
        throw CKDecodingError.missingField(key)
    }

    func penniesOptional(forKey key: String) -> Int64? {
        guard self[key] != nil else { return nil }
        do {
            return try pennies(forKey: key)
        } catch {
            return nil
        }
    }

    func extract<T>(_ key: String) throws -> T {
        guard let value = self[key] as? T else {
            throw CKDecodingError.missingField(key)
        }
        return value
    }

    func extractOptional<T>(_ key: String) -> T? {
        self[key] as? T
    }
}

extension Family: CloudKitRecord {
    static var managedFieldKeys: Set<String> {
        ["name", "createdBy", "createdAt", "payoutPolicy", "payoutDay"]
    }
}

extension Profile: CloudKitRecord {
    static var managedFieldKeys: Set<String> {
        [
            "displayName",
            "avatarClass",
            "avatarPresetID",
            "customAvatarImageData",
            "role",
            "xp",
            "level",
            "gems",
            "streakShields",
            "mascotCompanion",
            "iCloudUserID",
            "family",
            "isActive",
            "payoutPolicy",
            "payoutDay",
            "ownedEquipment",
            "equippedItems",
            "dailyLoginLastClaimDay",
            "dailyLoginCycleDay",
            "dailyLoginStreakDays",
            "claimedBonusObjectives",
            "journeyMapLastSeenLevel",
            "avatarEmoji",
            "splitPercentSpend",
            "splitPercentShort",
            "splitPercentLong",
            "interestEnabled",
            "interestBucket",
            "interestRateBps",
            "interestIsCompound",
            "matchEnabled",
            "matchRateBps",
            "matchMonthlyCapPennies"
        ]
    }
}

extension QuestTemplate: CloudKitRecord {
    static var managedFieldKeys: Set<String> {
        [
            "name",
            "description",
            "defaultGold",
            "xpReward",
            "scheduleType",
            "specificDays",
            "targetCount",
            "isAllOrNothing",
            "approvalMode",
            "createdBy",
            "family",
            "isActive"
        ]
    }
}

extension Quest: CloudKitRecord {
    static var managedFieldKeys: Set<String> {
        [
            "template",
            "assignee",
            "goldReward",
            "xpReward",
            "xpBanked",
            "scheduleType",
            "targetCount",
            "isAllOrNothing",
            "approvalMode",
            "active",
            "weekOf",
            "createdBy",
            "family",
            "name",
            "descriptionText",
            "claimedByProfileRecordName",
            "claimedAt"
        ]
    }
}

extension QuestCompletion: CloudKitRecord {
    static var managedFieldKeys: Set<String> {
        [
            "quest",
            "completedBy",
            "completedDate",
            "verificationStatus",
            "verifiedBy",
            "verifiedDate",
            "xpCredited",
            "weekOf",
            "family"
        ]
    }
}

extension AllowancePeriod: CloudKitRecord {
    static var managedFieldKeys: Set<String> {
        [
            "weekOf",
            "profile",
            "status",
            "totalEarned",
            "questsCompleted",
            "questsTotal",
            "paidDate",
            "paidAmount",
            "family"
        ]
    }
}

extension LedgerEntry: CloudKitRecord {
    static var managedFieldKeys: Set<String> {
        [
            "profile",
            "amount",
            "description",
            "location",
            "date",
            "source",
            "bucketKind",
            "fromBucket",
            "toBucket",
            "family"
        ]
    }
}

extension Achievement: CloudKitRecord {
    static var managedFieldKeys: Set<String> {
        [
            "name",
            "description",
            "iconSystemName",
            "category",
            "requirementType",
            "requirementValue",
            "family"
        ]
    }
}

extension ProfileAchievement: CloudKitRecord {
    static var managedFieldKeys: Set<String> {
        [
            "achievement",
            "profile",
            "earnedDate",
            "family"
        ]
    }
}

extension NotificationPreference: CloudKitRecord {
    static var managedFieldKeys: Set<String> {
        [
            "profile",
            "eventType",
            "enabled",
            "family"
        ]
    }
}

extension RewardEvent {
    static var managedFieldKeys: Set<String> {
        [
            "profile",
            "questCompletion",
            "xpAmount",
            "goldAmount",
            "timestamp",
            "family"
        ]
    }
}

extension Family: CacheMergeableDomain {}
extension Profile: CacheMergeableDomain {}
extension QuestTemplate: CacheMergeableDomain {}
extension Quest: CacheMergeableDomain {}
extension QuestCompletion: CacheMergeableDomain {}
extension AllowancePeriod: CacheMergeableDomain {}
extension LedgerEntry: CacheMergeableDomain {}
extension Achievement: CacheMergeableDomain {}
extension ProfileAchievement: CacheMergeableDomain {}
extension NotificationPreference: CacheMergeableDomain {}
extension RewardEvent: CacheMergeableDomain {}
extension Goal: CacheMergeableDomain {}

enum CKDecodingError: Error, Equatable, Sendable {
    case unexpectedRecordType(expected: String, actual: String)

    case missingField(String)
}
