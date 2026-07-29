//
//  CacheConversions.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import SwiftData

extension QuestCache {
    func toQuest(zoneID: CKRecordZone.ID) -> Quest {
        Quest(
            template: CKRecord.Reference(recordID: CKRecord.ID(recordName: templateRecordName, zoneID: zoneID), action: .none),
            assignee: CKRecord.Reference(recordID: CKRecord.ID(recordName: assigneeRecordName, zoneID: zoneID), action: .none),
            goldReward: goldReward,
            xpReward: xpReward,
            scheduleType: QuestSchedule(rawValue: scheduleType) ?? .weeklyFlexible,
            isAllOrNothing: isAllOrNothing,
            approvalMode: ApprovalMode(rawValue: approvalMode) ?? .autoApprove,
            weekOf: weekOf,
            createdBy: CKRecord.Reference(recordID: CKRecord.ID(recordName: createdByRecordName, zoneID: zoneID), action: .none),
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: familyRecordName, zoneID: zoneID), action: .none),
            name: questName,
            descriptionText: descriptionText,
            id: CKRecord.ID(recordName: recordName, zoneID: zoneID)
        )
    }
}

extension QuestCompletionCache {
    func toQuestCompletion(zoneID: CKRecordZone.ID) -> QuestCompletion {
        var completion = QuestCompletion(
            quest: CKRecord.Reference(recordID: CKRecord.ID(recordName: questRecordName, zoneID: zoneID), action: .none),
            completedBy: CKRecord.Reference(recordID: CKRecord.ID(recordName: completerRecordName, zoneID: zoneID), action: .none),
            approvalMode: approvalModeEnum,
            weekOf: weekOf,
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: familyRecordName, zoneID: zoneID), action: .none),
            id: CKRecord.ID(recordName: recordName, zoneID: zoneID)
        )
        completion.completedDate = completedDate
        completion.verificationStatus = VerificationStatus(rawValue: verificationStatus) ?? .pending
        if let verifiedByName = verifiedByRecordName {
            completion.verifiedBy = CKRecord.Reference(recordID: CKRecord.ID(recordName: verifiedByName, zoneID: zoneID), action: .none)
        }
        completion.verifiedDate = verifiedDate
        return completion
    }
}

extension QuestTemplateCache {
    func toQuestTemplate(zoneID: CKRecordZone.ID) -> QuestTemplate {
        QuestTemplate(
            name: name,
            description: templateDescription,
            defaultGold: goldReward,
            xpReward: xpReward,
            scheduleType: QuestSchedule(rawValue: scheduleType) ?? .weeklyFlexible,
            specificDays: specificDays ?? [],
            isAllOrNothing: isAllOrNothing,
            approvalMode: ApprovalMode(rawValue: approvalMode) ?? .autoApprove,
            createdBy: CKRecord.Reference(recordID: CKRecord.ID(recordName: createdByRecordName, zoneID: zoneID), action: .none),
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: familyRecordName, zoneID: zoneID), action: .none),
            isActive: isActive,
            id: CKRecord.ID(recordName: recordName, zoneID: zoneID)
        )
    }
}

extension ProfileCache {
    func toProfile(zoneID: CKRecordZone.ID) -> Profile {
        var profile = Profile(
            displayName: displayName,
            avatarClass: AvatarClass(rawValue: avatarClass ?? ""),
            avatarPresetID: avatarName,
            customAvatarImageData: customAvatarImageData,
            role: UserRole(rawValue: role) ?? .hero,
            iCloudUserID: CKRecord.ID(recordName: iCloudUserRecordName, zoneID: zoneID),
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: familyRecordName, zoneID: zoneID), action: .none),
            payoutPolicy: PayoutPolicy(rawValue: payoutPolicy) ?? .perQuest,
            id: CKRecord.ID(recordName: recordName, zoneID: zoneID)
        )
        profile.xp = xpTotal
        profile.level = level
        profile.isActive = isActive
        return profile
    }
}

extension LedgerEntryCache {
    func toLedgerEntry(zoneID: CKRecordZone.ID) -> LedgerEntry {
        LedgerEntry(
            profile: CKRecord.Reference(recordID: CKRecord.ID(recordName: profileRecordName, zoneID: zoneID), action: .none),
            amount: amount,
            description: entryDescription,
            date: date,
            source: source,
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: familyRecordName, zoneID: zoneID), action: .none),
            id: CKRecord.ID(recordName: recordName, zoneID: zoneID)
        )
    }
}

extension AchievementCache {
    func toAchievement(zoneID: CKRecordZone.ID) -> Achievement {
        Achievement(
            name: name,
            description: achievementDescription,
            iconSystemName: iconSystemName,
            category: AchievementCategory(rawValue: category) ?? .quest,
            requirementType: AchievementRequirement(rawValue: requirementType) ?? .firstQuest,
            requirementValue: requirementValue,
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: familyRecordName, zoneID: zoneID), action: .none),
            id: CKRecord.ID(recordName: recordName, zoneID: zoneID)
        )
    }
}

extension ProfileAchievementCache {
    func toProfileAchievement(zoneID: CKRecordZone.ID) -> ProfileAchievement {
        ProfileAchievement(
            achievement: CKRecord.Reference(recordID: CKRecord.ID(recordName: achievementRecordName, zoneID: zoneID), action: .none),
            profile: CKRecord.Reference(recordID: CKRecord.ID(recordName: profileRecordName, zoneID: zoneID), action: .none),
            earnedDate: earnedDate,
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: familyRecordName, zoneID: zoneID), action: .none),
            id: CKRecord.ID(recordName: recordName, zoneID: zoneID)
        )
    }
}

extension AllowancePeriodCache {
    func toAllowancePeriod(zoneID: CKRecordZone.ID) -> AllowancePeriod {
        var period = AllowancePeriod(
            weekOf: weekOf,
            profile: CKRecord.Reference(recordID: CKRecord.ID(recordName: profileRecordName, zoneID: zoneID), action: .none),
            questsTotal: questsTotal,
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: familyRecordName, zoneID: zoneID), action: .none),
            id: CKRecord.ID(recordName: recordName, zoneID: zoneID)
        )
        period.status = PayoutStatus(rawValue: status) ?? .active
        period.totalEarned = totalEarned
        period.questsCompleted = questsCompleted
        period.paidDate = paidDate
        period.paidAmount = paidAmount
        return period
    }
}

extension FamilyCache {
    func toFamily(zoneID: CKRecordZone.ID) -> Family {
        Family(
            name: name,
            createdBy: CKRecord.ID(recordName: createdByRecordName, zoneID: zoneID),
            payoutPolicy: PayoutPolicy(rawValue: payoutPolicy) ?? .perQuest,
            id: CKRecord.ID(recordName: recordName, zoneID: zoneID)
        )
    }
}

extension NotificationPreferenceCache {
    func toNotificationPreference(zoneID: CKRecordZone.ID) -> NotificationPreference {
        NotificationPreference(
            profile: CKRecord.Reference(recordID: CKRecord.ID(recordName: profileRecordName, zoneID: zoneID), action: .none),
            eventType: NotificationEventType(rawValue: eventType) ?? .questAssigned,
            enabled: enabled,
            pushEnabled: pushEnabled,
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: familyRecordName, zoneID: zoneID), action: .none),
            id: CKRecord.ID(recordName: recordName, zoneID: zoneID)
        )
    }
}

// MARK: - Direct Enum Getters for SwiftUI Views

extension QuestCache {
    var approvalModeEnum: ApprovalMode {
        ApprovalMode(rawValue: approvalMode) ?? .autoApprove
    }

    var rarityEnum: QuestRarity {
        QuestRarity(rawValue: rarity) ?? .common
    }

    var scheduleTypeEnum: QuestSchedule {
        QuestSchedule(rawValue: scheduleType) ?? .weeklyFlexible
    }
}

extension QuestCompletionCache {
    var verificationStatusEnum: VerificationStatus {
        VerificationStatus(rawValue: verificationStatus) ?? .pending
    }

    var approvalModeEnum: ApprovalMode {
        ApprovalMode(rawValue: approvalMode) ?? .autoApprove
    }
}

extension ProfileCache {
    var roleEnum: UserRole {
        UserRole(rawValue: role) ?? .hero
    }

    var payoutPolicyEnum: PayoutPolicy {
        PayoutPolicy(rawValue: payoutPolicy) ?? .perQuest
    }

    var avatarClassEnum: AvatarClass? {
        guard let avatarClass else { return nil }
        return AvatarClass(rawValue: avatarClass)
    }
}

extension AllowancePeriodCache {
    var statusEnum: PayoutStatus {
        PayoutStatus(rawValue: status) ?? .active
    }
}

extension AchievementCache {
    var categoryEnum: AchievementCategory {
        AchievementCategory(rawValue: category) ?? .quest
    }

    var requirementTypeEnum: AchievementRequirement {
        AchievementRequirement(rawValue: requirementType) ?? .firstQuest
    }
}

extension QuestTemplateCache {
    var scheduleTypeEnum: QuestSchedule {
        QuestSchedule(rawValue: scheduleType) ?? .weeklyFlexible
    }

    var rarityEnum: QuestRarity {
        QuestRarity.from(xp: xpReward)
    }

    var approvalModeEnum: ApprovalMode {
        ApprovalMode(rawValue: approvalMode) ?? .autoApprove
    }
}
