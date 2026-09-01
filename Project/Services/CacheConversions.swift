//
//  CacheConversions.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import os
import SwiftData

private let cacheConversionsLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "LootList",
    category: "CacheConversions"
)

/// Returns private/shared from zone owner — private zones use default owner or non-underscore names
/// (tests), shared zones start with "_".
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

    func validatedDatabaseScope(expectedScope: CKDatabase.Scope) -> CKDatabase.Scope? {
        guard let persisted = persistedDatabaseScope else { return expectedScope }
        guard persisted == expectedScope else {
            cacheConversionsLogger.warning(
                "Database scope mismatch: expected \(String(describing: expectedScope), privacy: .public) got \(self.sourceDatabaseScope ?? "nil", privacy: .private)"
            )
            return nil
        }
        return persisted
    }
}

/// Shared system-field handling so each toDomain copy doesn't repeat
/// validatedZoneID + changeTag/encodedSystemFields boilerplate.
protocol DomainSystemFields {
    var changeTag: String? { get set }
    var encodedSystemFields: Data? { get set }
}

protocol CacheSystemFields: FamilyScopedCache {
    var changeTag: String? { get set }
    var encodedSystemFields: Data? { get set }
}

extension CacheSystemFields {
    /// Builds domain via closure on the effective zone, then rehydrates
    /// server-owned fields that must propagate even when nil.
    func domain<T: DomainSystemFields>(
        zoneID: CKRecordZone.ID,
        build: (CKRecordZone.ID) -> T
    ) -> T {
        let zid = validatedZoneID(requestedZoneID: zoneID)
        var domain = build(zid)
        domain.changeTag = changeTag
        domain.encodedSystemFields = encodedSystemFields
        return domain
    }
}

extension Quest: DomainSystemFields {}
extension QuestCompletion: DomainSystemFields {}
extension QuestTemplate: DomainSystemFields {}
extension Profile: DomainSystemFields {}
extension LedgerEntry: DomainSystemFields {}
extension Achievement: DomainSystemFields {}
extension ProfileAchievement: DomainSystemFields {}
extension AllowancePeriod: DomainSystemFields {}
extension Family: DomainSystemFields {}
extension NotificationPreference: DomainSystemFields {}
extension GemLedger: DomainSystemFields {}
extension RewardEvent: DomainSystemFields {}
extension Goal: DomainSystemFields {}

// WHY: Blanket extension unsupported in this toolchain; 13 explicit conformances are minimal.
extension QuestCache: CacheSystemFields {}
extension QuestCompletionCache: CacheSystemFields {}
extension QuestTemplateCache: CacheSystemFields {}
extension ProfileCache: CacheSystemFields {}
extension LedgerEntryCache: CacheSystemFields {}
extension AchievementCache: CacheSystemFields {}
extension ProfileAchievementCache: CacheSystemFields {}
extension AllowancePeriodCache: CacheSystemFields {}
extension FamilyCache: CacheSystemFields {}
extension NotificationPreferenceCache: CacheSystemFields {}
extension GemLedgerCache: CacheSystemFields {}
extension RewardEventCache: CacheSystemFields {}
extension GoalCache: CacheSystemFields {}

extension QuestCache {
    func toQuest(zoneID: CKRecordZone.ID) -> Quest {
        domain(zoneID: zoneID) { zid in
            Quest(
                template: CKRecord.Reference(recordID: CKRecord.ID(recordName: templateRecordName, zoneID: zid), action: .none),
                assignee: CKRecord.Reference(recordID: CKRecord.ID(recordName: assigneeRecordName, zoneID: zid), action: .none),
                goldReward: goldReward,
                xpReward: xpReward,
                scheduleType: QuestSchedule(rawValue: scheduleType) ?? .weeklyFlexible,
                targetCount: targetCount,
                isAllOrNothing: isAllOrNothing,
                approvalMode: ApprovalMode(rawValue: approvalMode) ?? .autoApprove,
                weekOf: weekOf,
                createdBy: CKRecord.Reference(recordID: CKRecord.ID(recordName: createdByRecordName, zoneID: zid), action: .none),
                family: CKRecord.Reference(recordID: CKRecord.ID(recordName: familyRecordName, zoneID: zid), action: .none),
                name: questName,
                descriptionText: descriptionText,
                xpBanked: xpBanked,
                claimedByProfileRecordName: claimedByProfileRecordName,
                claimedAt: claimedAt,
                id: CKRecord.ID(recordName: recordName, zoneID: zid)
            )
        }
    }

    func toDomain(zoneID: CKRecordZone.ID) -> Quest {
        toQuest(zoneID: zoneID)
    }
}

extension QuestCompletionCache {
    func toQuestCompletion(zoneID: CKRecordZone.ID) -> QuestCompletion {
        domain(zoneID: zoneID) { zid in
            var completion = QuestCompletion(
                quest: CKRecord.Reference(
                    recordID: CKRecord.ID(recordName: questRecordName, zoneID: zid),
                    action: .none
                ),
                completedBy: CKRecord.Reference(
                    recordID: CKRecord.ID(recordName: completerRecordName, zoneID: zid),
                    action: .none
                ),
                approvalMode: approvalModeEnum ?? .autoApprove,
                weekOf: weekOf,
                family: CKRecord.Reference(
                    recordID: CKRecord.ID(recordName: familyRecordName, zoneID: zid),
                    action: .none
                ),
                id: CKRecord.ID(recordName: recordName, zoneID: zid)
            )
            completion.completedDate = completedDate
            completion.verificationStatus = VerificationStatus(
                rawValue: verificationStatus
            ) ?? .pending
            if let verifiedName = verifiedByRecordName {
                completion.verifiedBy = CKRecord.Reference(
                    recordID: CKRecord.ID(recordName: verifiedName, zoneID: zid),
                    action: .none
                )
            }
            completion.verifiedDate = verifiedDate
            completion.xpCredited = xpCredited
            return completion
        }
    }

    func toDomain(zoneID: CKRecordZone.ID) -> QuestCompletion {
        toQuestCompletion(zoneID: zoneID)
    }
}

extension QuestTemplateCache {
    func toQuestTemplate(zoneID: CKRecordZone.ID) -> QuestTemplate {
        domain(zoneID: zoneID) { zid in
            QuestTemplate(
                name: name,
                description: templateDescription,
                defaultGold: goldReward,
                xpReward: xpReward,
                scheduleType: QuestSchedule(rawValue: scheduleType) ?? .weeklyFlexible,
                specificDays: specificDays ?? [],
                targetCount: targetCount,
                isAllOrNothing: isAllOrNothing,
                approvalMode: ApprovalMode(rawValue: approvalMode) ?? .autoApprove,
                createdBy: CKRecord.Reference(recordID: CKRecord.ID(recordName: createdByRecordName, zoneID: zid), action: .none),
                family: CKRecord.Reference(recordID: CKRecord.ID(recordName: familyRecordName, zoneID: zid), action: .none),
                isActive: isActive,
                id: CKRecord.ID(recordName: recordName, zoneID: zid)
            )
        }
    }

    func toDomain(zoneID: CKRecordZone.ID) -> QuestTemplate {
        toQuestTemplate(zoneID: zoneID)
    }
}

extension ProfileCache {
    func toProfile(zoneID: CKRecordZone.ID) -> Profile {
        domain(zoneID: zoneID) { zid in
            var profile = Profile(
                displayName: displayName,
                avatarClass: AvatarClass(rawValue: avatarClass ?? ""),
                avatarPresetID: avatarName,
                customAvatarImageData: customAvatarImageData,
                role: UserRole(rawValue: role) ?? .hero,
                iCloudUserID: CKRecord.ID(recordName: iCloudUserRecordName, zoneID: zid),
                family: CKRecord.Reference(recordID: CKRecord.ID(recordName: familyRecordName, zoneID: zid), action: .none),
                payoutPolicy: payoutPolicyEnum,
                payoutDay: payoutDay.flatMap { PayoutDay(rawValue: $0) },
                gems: gemsTotal,
                streakShields: streakShields,
                ownedEquipment: ownedEquipment ?? [],
                equippedItems: equippedItems ?? [],
                dailyLoginLastClaimDay: dailyLoginLastClaimDay,
                dailyLoginCycleDay: dailyLoginCycleDay,
                dailyLoginStreakDays: dailyLoginStreakDays,
                claimedBonusObjectives: claimedBonusObjectives ?? [],
                journeyMapLastSeenLevel: journeyMapLastSeenLevel,
                avatarEmoji: avatarEmoji,
                splitPercentSpend: splitPercentSpend,
                splitPercentShort: splitPercentShort,
                splitPercentLong: splitPercentLong,
                interestEnabled: interestEnabled,
                interestBucket: interestBucket,
                interestRateBps: interestRateBps,
                interestIsCompound: interestIsCompound,
                matchEnabled: matchEnabled,
                matchRateBps: matchRateBps,
                matchMonthlyCapPennies: matchMonthlyCapPennies,
                id: CKRecord.ID(recordName: recordName, zoneID: zid)
            )
            profile.xp = xpTotal
            profile.level = level
            profile.isActive = isActive
            return profile
        }
    }

    func toDomain(zoneID: CKRecordZone.ID) -> Profile {
        toProfile(zoneID: zoneID)
    }
}

extension LedgerEntryCache {
    func toLedgerEntry(zoneID: CKRecordZone.ID) -> LedgerEntry {
        domain(zoneID: zoneID) { zid in
            LedgerEntry(
                profile: CKRecord.Reference(recordID: CKRecord.ID(recordName: profileRecordName, zoneID: zid), action: .none),
                amount: amount,
                description: entryDescription,
                location: location,
                date: date,
                source: source,
                bucketKind: bucketKind,
                fromBucket: fromBucket,
                toBucket: toBucket,
                family: CKRecord.Reference(recordID: CKRecord.ID(recordName: familyRecordName, zoneID: zid), action: .none),
                id: CKRecord.ID(recordName: recordName, zoneID: zid)
            )
        }
    }

    func toDomain(zoneID: CKRecordZone.ID) -> LedgerEntry {
        toLedgerEntry(zoneID: zoneID)
    }
}

extension GoalCache {
    func toGoal(zoneID: CKRecordZone.ID) -> Goal {
        domain(zoneID: zoneID) { zid in
            Goal(
                profile: CKRecord.Reference(recordID: CKRecord.ID(recordName: profileRecordName, zoneID: zid), action: .none),
                family: CKRecord.Reference(recordID: CKRecord.ID(recordName: familyRecordName, zoneID: zid), action: .none),
                bucketKind: bucketKindEnum ?? .spend,
                name: name,
                category: category,
                emojiIcon: emojiIcon,
                targetAmountPennies: targetAmountPennies,
                createdAt: createdAt,
                completedAt: completedAt,
                isArchived: isArchived,
                targetDate: targetDate,
                linkURL: linkURL,
                imageURL: imageURL,
                id: CKRecord.ID(recordName: recordName, zoneID: zid)
            )
        }
    }

    func toDomain(zoneID: CKRecordZone.ID) -> Goal {
        toGoal(zoneID: zoneID)
    }
}

extension AchievementCache {
    func toAchievement(zoneID: CKRecordZone.ID) -> Achievement {
        domain(zoneID: zoneID) { zid in
            Achievement(
                name: name,
                description: achievementDescription,
                iconSystemName: iconSystemName,
                category: AchievementCategory(rawValue: category) ?? .quest,
                requirementType: AchievementRequirement(rawValue: requirementType) ?? .firstQuest,
                requirementValue: requirementValue,
                family: CKRecord.Reference(recordID: CKRecord.ID(recordName: familyRecordName, zoneID: zid), action: .none),
                id: CKRecord.ID(recordName: recordName, zoneID: zid)
            )
        }
    }

    func toDomain(zoneID: CKRecordZone.ID) -> Achievement {
        toAchievement(zoneID: zoneID)
    }
}

extension ProfileAchievementCache {
    func toProfileAchievement(zoneID: CKRecordZone.ID) -> ProfileAchievement {
        domain(zoneID: zoneID) { zid in
            ProfileAchievement(
                achievement: CKRecord.Reference(recordID: CKRecord.ID(recordName: achievementRecordName, zoneID: zid), action: .none),
                profile: CKRecord.Reference(recordID: CKRecord.ID(recordName: profileRecordName, zoneID: zid), action: .none),
                earnedDate: earnedDate,
                family: CKRecord.Reference(recordID: CKRecord.ID(recordName: familyRecordName, zoneID: zid), action: .none),
                id: CKRecord.ID(recordName: recordName, zoneID: zid)
            )
        }
    }

    func toDomain(zoneID: CKRecordZone.ID) -> ProfileAchievement {
        toProfileAchievement(zoneID: zoneID)
    }
}

extension AllowancePeriodCache {
    func toAllowancePeriod(zoneID: CKRecordZone.ID) -> AllowancePeriod {
        domain(zoneID: zoneID) { zid in
            var period = AllowancePeriod(
                weekOf: weekOf,
                profile: CKRecord.Reference(
                    recordID: CKRecord.ID(recordName: profileRecordName, zoneID: zid),
                    action: .none
                ),
                questsTotal: questsTotal,
                family: CKRecord.Reference(
                    recordID: CKRecord.ID(recordName: familyRecordName, zoneID: zid),
                    action: .none
                ),
                id: CKRecord.ID(recordName: recordName, zoneID: zid)
            )
            period.status = PayoutStatus(rawValue: status) ?? .active
            period.totalEarned = totalEarned
            period.questsCompleted = questsCompleted
            period.paidDate = paidDate
            period.paidAmount = paidAmount
            return period
        }
    }

    func toDomain(zoneID: CKRecordZone.ID) -> AllowancePeriod {
        toAllowancePeriod(zoneID: zoneID)
    }
}

extension FamilyCache {
    func toFamily(zoneID: CKRecordZone.ID) -> Family {
        domain(zoneID: zoneID) { zid in
            Family(
                name: name,
                createdBy: CKRecord.ID(recordName: createdByRecordName, zoneID: zid),
                payoutPolicy: PayoutPolicy(rawValue: payoutPolicy) ?? .perQuest,
                payoutDay: PayoutDay(rawValue: payoutDay) ?? .sunday,
                creatorUserRecordName: creatorUserRecordName,
                id: CKRecord.ID(recordName: recordName, zoneID: zid)
            )
        }
    }

    func toDomain(zoneID: CKRecordZone.ID) -> Family {
        toFamily(zoneID: zoneID)
    }
}

extension NotificationPreferenceCache {
    func toNotificationPreference(zoneID: CKRecordZone.ID) -> NotificationPreference {
        domain(zoneID: zoneID) { zid in
            NotificationPreference(
                profile: CKRecord.Reference(recordID: CKRecord.ID(recordName: profileRecordName, zoneID: zid), action: .none),
                eventType: NotificationEventType(rawValue: eventType) ?? .questAssigned,
                enabled: enabled,
                family: CKRecord.Reference(recordID: CKRecord.ID(recordName: familyRecordName, zoneID: zid), action: .none),
                id: CKRecord.ID(recordName: recordName, zoneID: zid)
            )
        }
    }

    func toDomain(zoneID: CKRecordZone.ID) -> NotificationPreference {
        toNotificationPreference(zoneID: zoneID)
    }
}

extension GemLedgerCache {
    func toGemLedger(zoneID: CKRecordZone.ID) -> GemLedger {
        domain(zoneID: zoneID) { zid in
            GemLedger(
                profileRecordName: profileRecordName,
                family: CKRecord.Reference(recordID: CKRecord.ID(recordName: familyRecordName, zoneID: zid), action: .none),
                amount: amount,
                source: source,
                sourceDetail: sourceDetail,
                createdAt: createdAt,
                id: CKRecord.ID(recordName: recordName, zoneID: zid)
            )
        }
    }

    func toDomain(zoneID: CKRecordZone.ID) -> GemLedger {
        toGemLedger(zoneID: zoneID)
    }
}

extension RewardEventCache {
    func toRewardEvent(zoneID: CKRecordZone.ID) -> RewardEvent {
        domain(zoneID: zoneID) { zid in
            RewardEvent(
                profile: CKRecord.Reference(recordID: CKRecord.ID(recordName: profileRecordName, zoneID: zid), action: .none),
                questCompletion: CKRecord.Reference(recordID: CKRecord.ID(recordName: questCompletionRecordName, zoneID: zid), action: .none),
                xpAmount: xpAmount,
                goldAmount: goldAmount,
                timestamp: timestamp,
                family: CKRecord.Reference(recordID: CKRecord.ID(recordName: familyRecordName, zoneID: zid), action: .none),
                id: CKRecord.ID(recordName: recordName, zoneID: zid)
            )
        }
    }

    func toDomain(zoneID: CKRecordZone.ID) -> RewardEvent {
        toRewardEvent(zoneID: zoneID)
    }
}
