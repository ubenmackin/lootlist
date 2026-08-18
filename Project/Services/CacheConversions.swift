//
//  CacheConversions.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import SwiftData

/// Infers database scope ("private" vs "shared") from a CloudKit zone ID.
/// In production, private database zones are owned by `CKCurrentUserDefaultName` ("__defaultOwner__"),
/// while shared zones carry an external user record name beginning with "_" (e.g. "_a1b2c3d4").
/// In unit tests/mock environments, non-prefixed owner names ("TestOwner", "Owner") represent private database zones.
func inferDatabaseScope(from zoneID: CKRecordZone.ID) -> String {
    let owner = zoneID.ownerName
    if owner == CKCurrentUserDefaultName || owner == "TestOwner" || owner == "Owner" || !owner.hasPrefix("_") {
        return "private"
    }
    return "shared"
}

extension FamilyScopedCache {
    var persistedDatabaseScope: CKDatabase.Scope? {
        guard let sourceDatabaseScope else { return nil }
        switch sourceDatabaseScope.lowercased() {
        case "private": return .private
        case "shared": return .shared
        case "public": return .public
        default: return nil
        }
    }

    func validatedZoneID(requestedZoneID: CKRecordZone.ID) -> CKRecordZone.ID {
        if let sourceZoneName, let sourceZoneOwnerName {
            return CKRecordZone.ID(zoneName: sourceZoneName, ownerName: sourceZoneOwnerName)
        } else if let sourceZoneName {
            return CKRecordZone.ID(zoneName: sourceZoneName, ownerName: requestedZoneID.ownerName)
        }
        return requestedZoneID
    }

    /// Validates the persisted database scope against an expected database scope with fail-closed semantics.
    /// Returns `nil` if the persisted scope is incompatible with the requested scope.
    func validatedDatabaseScope(expectedScope: CKDatabase.Scope) -> CKDatabase.Scope? {
        guard let persisted = persistedDatabaseScope else { return expectedScope }
        return persisted == expectedScope ? persisted : nil
    }
}

extension QuestCache {
    func toQuest(zoneID: CKRecordZone.ID) -> Quest {
        let effectiveZoneID = validatedZoneID(requestedZoneID: zoneID)
        var quest = Quest(
            template: CKRecord.Reference(recordID: CKRecord.ID(recordName: templateRecordName, zoneID: effectiveZoneID), action: .none),
            assignee: CKRecord.Reference(recordID: CKRecord.ID(recordName: assigneeRecordName, zoneID: effectiveZoneID), action: .none),
            goldReward: goldReward,
            xpReward: xpReward,
            scheduleType: QuestSchedule(rawValue: scheduleType) ?? .weeklyFlexible,
            targetCount: targetCount,
            isAllOrNothing: isAllOrNothing,
            approvalMode: ApprovalMode(rawValue: approvalMode) ?? .autoApprove,
            weekOf: weekOf,
            createdBy: CKRecord.Reference(recordID: CKRecord.ID(recordName: createdByRecordName, zoneID: effectiveZoneID), action: .none),
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: familyRecordName, zoneID: effectiveZoneID), action: .none),
            name: questName,
            descriptionText: descriptionText,
            xpBanked: xpBanked,
            id: CKRecord.ID(recordName: recordName, zoneID: effectiveZoneID)
        )
        // changeTag & encodedSystemFields rehydrated from cache row per toX(zoneID:).
        quest.changeTag = changeTag
        quest.encodedSystemFields = encodedSystemFields
        return quest
    }
}

extension QuestCompletionCache {
    func toQuestCompletion(zoneID: CKRecordZone.ID) -> QuestCompletion {
        let effectiveZoneID = validatedZoneID(requestedZoneID: zoneID)
        var completion = QuestCompletion(
            quest: CKRecord.Reference(recordID: CKRecord.ID(recordName: questRecordName, zoneID: effectiveZoneID), action: .none),
            completedBy: CKRecord.Reference(recordID: CKRecord.ID(recordName: completerRecordName, zoneID: effectiveZoneID), action: .none),
            approvalMode: approvalModeEnum ?? .autoApprove,
            weekOf: weekOf,
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: familyRecordName, zoneID: effectiveZoneID), action: .none),
            id: CKRecord.ID(recordName: recordName, zoneID: effectiveZoneID)
        )
        completion.completedDate = completedDate
        completion.verificationStatus = VerificationStatus(rawValue: verificationStatus) ?? .pending
        if let verifiedByName = verifiedByRecordName {
            completion.verifiedBy = CKRecord.Reference(recordID: CKRecord.ID(recordName: verifiedByName, zoneID: effectiveZoneID), action: .none)
        }
        completion.verifiedDate = verifiedDate
        completion.xpCredited = xpCredited
        // changeTag & encodedSystemFields rehydrated from cache row per toX(zoneID:).
        completion.changeTag = changeTag
        completion.encodedSystemFields = encodedSystemFields
        return completion
    }
}

extension QuestTemplateCache {
    func toQuestTemplate(zoneID: CKRecordZone.ID) -> QuestTemplate {
        let effectiveZoneID = validatedZoneID(requestedZoneID: zoneID)
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
            createdBy: CKRecord.Reference(recordID: CKRecord.ID(recordName: createdByRecordName, zoneID: effectiveZoneID), action: .none),
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: familyRecordName, zoneID: effectiveZoneID), action: .none),
            isActive: isActive,
            id: CKRecord.ID(recordName: recordName, zoneID: effectiveZoneID)
        )
        // changeTag & encodedSystemFields rehydrated from cache row per toX(zoneID:).
        template.changeTag = changeTag
        template.encodedSystemFields = encodedSystemFields
        return template
    }
}

extension ProfileCache {
    func toProfile(zoneID: CKRecordZone.ID) -> Profile {
        let effectiveZoneID = validatedZoneID(requestedZoneID: zoneID)
        var profile = Profile(
            displayName: displayName,
            avatarClass: AvatarClass(rawValue: avatarClass ?? ""),
            avatarPresetID: avatarName,
            customAvatarImageData: customAvatarImageData,
            role: UserRole(rawValue: role) ?? .hero,
            iCloudUserID: CKRecord.ID(recordName: iCloudUserRecordName, zoneID: effectiveZoneID),
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: familyRecordName, zoneID: effectiveZoneID), action: .none),
            payoutPolicy: PayoutPolicy(rawValue: payoutPolicy) ?? .perQuest,
            payoutDay: payoutDay.flatMap { PayoutDay(rawValue: $0) },
            gems: gemsTotal,
            streakShields: streakShields,
            ownedEquipment: ownedEquipment ?? [],
            equippedItems: equippedItems ?? [],
            dailyLoginLastClaimDay: dailyLoginLastClaimDay,
            dailyLoginCycleDay: dailyLoginCycleDay,
            dailyLoginStreakDays: dailyLoginStreakDays,
            claimedBonusObjectives: claimedBonusObjectives ?? [],
            id: CKRecord.ID(recordName: recordName, zoneID: effectiveZoneID)
        )
        profile.xp = xpTotal
        profile.level = level
        profile.isActive = isActive
        // changeTag & encodedSystemFields rehydrated from cache row per toX(zoneID:).
        profile.changeTag = changeTag
        profile.encodedSystemFields = encodedSystemFields
        return profile
    }
}

extension LedgerEntryCache {
    func toLedgerEntry(zoneID: CKRecordZone.ID) -> LedgerEntry {
        let effectiveZoneID = validatedZoneID(requestedZoneID: zoneID)
        var entry = LedgerEntry(
            profile: CKRecord.Reference(recordID: CKRecord.ID(recordName: profileRecordName, zoneID: effectiveZoneID), action: .none),
            amount: amount,
            description: entryDescription,
            location: location,
            date: date,
            source: source,
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: familyRecordName, zoneID: effectiveZoneID), action: .none),
            id: CKRecord.ID(recordName: recordName, zoneID: effectiveZoneID)
        )
        // changeTag & encodedSystemFields rehydrated from cache row per toX(zoneID:).
        entry.changeTag = changeTag
        entry.encodedSystemFields = encodedSystemFields
        return entry
    }
}

extension AchievementCache {
    func toAchievement(zoneID: CKRecordZone.ID) -> Achievement {
        let effectiveZoneID = validatedZoneID(requestedZoneID: zoneID)
        var achievement = Achievement(
            name: name,
            description: achievementDescription,
            iconSystemName: iconSystemName,
            category: AchievementCategory(rawValue: category) ?? .quest,
            requirementType: AchievementRequirement(rawValue: requirementType) ?? .firstQuest,
            requirementValue: requirementValue,
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: familyRecordName, zoneID: effectiveZoneID), action: .none),
            id: CKRecord.ID(recordName: recordName, zoneID: effectiveZoneID)
        )
        // changeTag & encodedSystemFields rehydrated from cache row per toX(zoneID:).
        achievement.changeTag = changeTag
        achievement.encodedSystemFields = encodedSystemFields
        return achievement
    }
}

extension ProfileAchievementCache {
    func toProfileAchievement(zoneID: CKRecordZone.ID) -> ProfileAchievement {
        let effectiveZoneID = validatedZoneID(requestedZoneID: zoneID)
        var pa = ProfileAchievement(
            achievement: CKRecord.Reference(recordID: CKRecord.ID(recordName: achievementRecordName, zoneID: effectiveZoneID), action: .none),
            profile: CKRecord.Reference(recordID: CKRecord.ID(recordName: profileRecordName, zoneID: effectiveZoneID), action: .none),
            earnedDate: earnedDate,
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: familyRecordName, zoneID: effectiveZoneID), action: .none),
            id: CKRecord.ID(recordName: recordName, zoneID: effectiveZoneID)
        )
        // changeTag & encodedSystemFields rehydrated from cache row per toX(zoneID:).
        pa.changeTag = changeTag
        pa.encodedSystemFields = encodedSystemFields
        return pa
    }
}

extension AllowancePeriodCache {
    func toAllowancePeriod(zoneID: CKRecordZone.ID) -> AllowancePeriod {
        let effectiveZoneID = validatedZoneID(requestedZoneID: zoneID)
        var period = AllowancePeriod(
            weekOf: weekOf,
            profile: CKRecord.Reference(recordID: CKRecord.ID(recordName: profileRecordName, zoneID: effectiveZoneID), action: .none),
            questsTotal: questsTotal,
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: familyRecordName, zoneID: effectiveZoneID), action: .none),
            id: CKRecord.ID(recordName: recordName, zoneID: effectiveZoneID)
        )
        period.status = PayoutStatus(rawValue: status) ?? .active
        period.totalEarned = totalEarned
        period.questsCompleted = questsCompleted
        period.paidDate = paidDate
        period.paidAmount = paidAmount
        // changeTag & encodedSystemFields rehydrated from cache row per toX(zoneID:).
        period.changeTag = changeTag
        period.encodedSystemFields = encodedSystemFields
        return period
    }
}

extension FamilyCache {
    var persistedDatabaseScope: CKDatabase.Scope? {
        guard let sourceDatabaseScope else { return nil }
        switch sourceDatabaseScope.lowercased() {
        case "private": return .private
        case "shared": return .shared
        case "public": return .public
        default: return nil
        }
    }

    func validatedZoneID(requestedZoneID: CKRecordZone.ID) -> CKRecordZone.ID {
        if let sourceZoneName, let sourceZoneOwnerName {
            return CKRecordZone.ID(zoneName: sourceZoneName, ownerName: sourceZoneOwnerName)
        } else if let sourceZoneName {
            return CKRecordZone.ID(zoneName: sourceZoneName, ownerName: requestedZoneID.ownerName)
        }
        return requestedZoneID
    }

    /// Validates the persisted database scope against an expected database scope with fail-closed semantics.
    /// Returns `nil` if the persisted scope is incompatible with the requested scope.
    func validatedDatabaseScope(expectedScope: CKDatabase.Scope) -> CKDatabase.Scope? {
        guard let persisted = persistedDatabaseScope else { return expectedScope }
        return persisted == expectedScope ? persisted : nil
    }

    func toFamily(zoneID: CKRecordZone.ID) -> Family {
        let effectiveZoneID = validatedZoneID(requestedZoneID: zoneID)
        var family = Family(
            name: name,
            createdBy: CKRecord.ID(recordName: createdByRecordName, zoneID: effectiveZoneID),
            payoutPolicy: PayoutPolicy(rawValue: payoutPolicy) ?? .perQuest,
            payoutDay: PayoutDay(rawValue: payoutDay) ?? .sunday,
            creatorUserRecordName: creatorUserRecordName,
            id: CKRecord.ID(recordName: recordName, zoneID: effectiveZoneID)
        )
        // changeTag & encodedSystemFields rehydrated from cache row per toX(zoneID:).
        family.changeTag = changeTag
        family.encodedSystemFields = encodedSystemFields
        return family
    }
}

extension NotificationPreferenceCache {
    func toNotificationPreference(zoneID: CKRecordZone.ID) -> NotificationPreference {
        let effectiveZoneID = validatedZoneID(requestedZoneID: zoneID)
        var preference = NotificationPreference(
            profile: CKRecord.Reference(recordID: CKRecord.ID(recordName: profileRecordName, zoneID: effectiveZoneID), action: .none),
            eventType: NotificationEventType(rawValue: eventType) ?? .questAssigned,
            enabled: enabled,
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: familyRecordName, zoneID: effectiveZoneID), action: .none),
            id: CKRecord.ID(recordName: recordName, zoneID: effectiveZoneID)
        )
        // changeTag & encodedSystemFields rehydrated from cache row per toX(zoneID:).
        preference.changeTag = changeTag
        preference.encodedSystemFields = encodedSystemFields
        return preference
    }
}

extension GemLedgerCache {
    func toGemLedger(zoneID: CKRecordZone.ID) -> GemLedger {
        let effectiveZoneID = validatedZoneID(requestedZoneID: zoneID)
        var ledger = GemLedger(
            profileRecordName: profileRecordName,
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: familyRecordName, zoneID: effectiveZoneID), action: .none),
            amount: amount,
            source: source,
            sourceDetail: sourceDetail,
            createdAt: createdAt,
            id: CKRecord.ID(recordName: recordName, zoneID: effectiveZoneID)
        )
        ledger.changeTag = changeTag
        ledger.encodedSystemFields = encodedSystemFields
        return ledger
    }
}

extension RewardEventCache {
    func toRewardEvent(zoneID: CKRecordZone.ID) -> RewardEvent {
        let effectiveZoneID = validatedZoneID(requestedZoneID: zoneID)
        var event = RewardEvent(
            profile: CKRecord.Reference(recordID: CKRecord.ID(recordName: profileRecordName, zoneID: effectiveZoneID), action: .none),
            questCompletion: CKRecord.Reference(recordID: CKRecord.ID(recordName: questCompletionRecordName, zoneID: effectiveZoneID), action: .none),
            xpAmount: xpAmount,
            goldAmount: goldAmount,
            timestamp: timestamp,
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: familyRecordName, zoneID: effectiveZoneID), action: .none),
            id: CKRecord.ID(recordName: recordName, zoneID: effectiveZoneID)
        )
        event.changeTag = changeTag
        event.encodedSystemFields = encodedSystemFields
        return event
    }
}
