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
        var quest = Quest(
            template: CKRecord.Reference(recordID: CKRecord.ID(recordName: templateRecordName, zoneID: zoneID), action: .none),
            assignee: CKRecord.Reference(recordID: CKRecord.ID(recordName: assigneeRecordName, zoneID: zoneID), action: .none),
            goldReward: goldReward,
            xpReward: xpReward,
            scheduleType: QuestSchedule(rawValue: scheduleType) ?? .weeklyFlexible,
            targetCount: targetCount,
            isAllOrNothing: isAllOrNothing,
            approvalMode: ApprovalMode(rawValue: approvalMode) ?? .autoApprove,
            weekOf: weekOf,
            createdBy: CKRecord.Reference(recordID: CKRecord.ID(recordName: createdByRecordName, zoneID: zoneID), action: .none),
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: familyRecordName, zoneID: zoneID), action: .none),
            name: questName,
            descriptionText: descriptionText,
            id: CKRecord.ID(recordName: recordName, zoneID: zoneID)
        )
        // changeTag rehydrated from cache row per toX(zoneID:), safe for use in ConcurrentEditDetector.
        quest.changeTag = changeTag
        return quest
    }
}

extension QuestCompletionCache {
    func toQuestCompletion(zoneID: CKRecordZone.ID) -> QuestCompletion {
        var completion = QuestCompletion(
            quest: CKRecord.Reference(recordID: CKRecord.ID(recordName: questRecordName, zoneID: zoneID), action: .none),
            completedBy: CKRecord.Reference(recordID: CKRecord.ID(recordName: completerRecordName, zoneID: zoneID), action: .none),
            approvalMode: approvalModeEnum ?? .autoApprove,
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
        // changeTag rehydrated from cache row per toX(zoneID:), safe for use in ConcurrentEditDetector.
        completion.changeTag = changeTag
        return completion
    }
}

extension QuestTemplateCache {
    func toQuestTemplate(zoneID: CKRecordZone.ID) -> QuestTemplate {
        var template = QuestTemplate(
            name: name,
            description: templateDescription,
            defaultGold: goldReward,
            xpReward: xpReward,
            scheduleType: QuestSchedule(rawValue: scheduleType) ?? .weeklyFlexible,
            specificDays: specificDays ?? [],
            targetCount: targetCount,
            isAllOrNothing: isAllOrNothing,
            approvalMode: ApprovalMode(rawValue: approvalMode) ?? .autoApprove,
            createdBy: CKRecord.Reference(recordID: CKRecord.ID(recordName: createdByRecordName, zoneID: zoneID), action: .none),
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: familyRecordName, zoneID: zoneID), action: .none),
            isActive: isActive,
            id: CKRecord.ID(recordName: recordName, zoneID: zoneID)
        )
        // changeTag rehydrated from cache row per toX(zoneID:), safe for use in ConcurrentEditDetector.
        template.changeTag = changeTag
        return template
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
        // changeTag rehydrated from cache row per toX(zoneID:), safe for use in ConcurrentEditDetector.
        profile.changeTag = changeTag
        return profile
    }
}

extension LedgerEntryCache {
    func toLedgerEntry(zoneID: CKRecordZone.ID) -> LedgerEntry {
        var entry = LedgerEntry(
            profile: CKRecord.Reference(recordID: CKRecord.ID(recordName: profileRecordName, zoneID: zoneID), action: .none),
            amount: amount,
            description: entryDescription,
            date: date,
            source: source,
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: familyRecordName, zoneID: zoneID), action: .none),
            id: CKRecord.ID(recordName: recordName, zoneID: zoneID)
        )
        // changeTag rehydrated from cache row per toX(zoneID:), safe for use in ConcurrentEditDetector.
        entry.changeTag = changeTag
        return entry
    }
}

extension AchievementCache {
    func toAchievement(zoneID: CKRecordZone.ID) -> Achievement {
        var achievement = Achievement(
            name: name,
            description: achievementDescription,
            iconSystemName: iconSystemName,
            category: AchievementCategory(rawValue: category) ?? .quest,
            requirementType: AchievementRequirement(rawValue: requirementType) ?? .firstQuest,
            requirementValue: requirementValue,
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: familyRecordName, zoneID: zoneID), action: .none),
            id: CKRecord.ID(recordName: recordName, zoneID: zoneID)
        )
        // changeTag rehydrated from cache row per toX(zoneID:), safe for use in ConcurrentEditDetector.
        achievement.changeTag = changeTag
        return achievement
    }
}

extension ProfileAchievementCache {
    func toProfileAchievement(zoneID: CKRecordZone.ID) -> ProfileAchievement {
        var pa = ProfileAchievement(
            achievement: CKRecord.Reference(recordID: CKRecord.ID(recordName: achievementRecordName, zoneID: zoneID), action: .none),
            profile: CKRecord.Reference(recordID: CKRecord.ID(recordName: profileRecordName, zoneID: zoneID), action: .none),
            earnedDate: earnedDate,
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: familyRecordName, zoneID: zoneID), action: .none),
            id: CKRecord.ID(recordName: recordName, zoneID: zoneID)
        )
        // changeTag rehydrated from cache row per toX(zoneID:), safe for use in ConcurrentEditDetector.
        pa.changeTag = changeTag
        return pa
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
        // changeTag rehydrated from cache row per toX(zoneID:), safe for use in ConcurrentEditDetector.
        period.changeTag = changeTag
        return period
    }
}

extension FamilyCache {
    func toFamily(zoneID: CKRecordZone.ID) -> Family {
        var family = Family(
            name: name,
            createdBy: CKRecord.ID(recordName: createdByRecordName, zoneID: zoneID),
            payoutPolicy: PayoutPolicy(rawValue: payoutPolicy) ?? .perQuest,
            id: CKRecord.ID(recordName: recordName, zoneID: zoneID)
        )
        // changeTag rehydrated from cache row per toX(zoneID:), safe for use in ConcurrentEditDetector.
        family.changeTag = changeTag
        return family
    }
}

extension NotificationPreferenceCache {
    func toNotificationPreference(zoneID: CKRecordZone.ID) -> NotificationPreference {
        var preference = NotificationPreference(
            profile: CKRecord.Reference(recordID: CKRecord.ID(recordName: profileRecordName, zoneID: zoneID), action: .none),
            eventType: NotificationEventType(rawValue: eventType) ?? .questAssigned,
            enabled: enabled,
            pushEnabled: pushEnabled,
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: familyRecordName, zoneID: zoneID), action: .none),
            id: CKRecord.ID(recordName: recordName, zoneID: zoneID)
        )
        // changeTag rehydrated from cache row per toX(zoneID:), safe for use in ConcurrentEditDetector.
        preference.changeTag = changeTag
        return preference
    }
}
