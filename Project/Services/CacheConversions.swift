import CloudKit
import Foundation
import SwiftData

extension QuestCache {
    func toQuest(zoneID: CKRecordZone.ID) -> Quest {
        Quest(
            template: CKRecord.Reference(recordID: CKRecord.ID(recordName: templateRecordName ?? "", zoneID: zoneID), action: .none),
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
            approvalMode: .autoApprove,
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
            customAvatarImageData: nil,
            role: UserRole(rawValue: role) ?? .hero,
            iCloudUserID: CKRecord.ID(recordName: iCloudUserRecordName),
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
