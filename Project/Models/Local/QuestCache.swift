//
//  QuestCache.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import SwiftData

@Model
final class QuestCache: FamilyScopedCache, CacheMergeable {
    typealias DomainModel = Quest

    #Index<QuestCache>([\.familyRecordName, \.recordName], [\.familyRecordName, \.assigneeRecordName, \.weekOf])

    var recordName: String
    var familyRecordName: String
    var assigneeRecordName: String
    var templateRecordName: String
    var weekOf: Date
    var questName: String
    var isActive: Bool
    var goldReward: Double
    var xpReward: Int
    /// Cached copy of `Quest.xpBanked` (the server-authoritative XP-credit
    /// ledger total). Synced via `update(from:)`/`toQuest(zoneID:)` so the
    /// reward step can resolve the freshest banked total cache-first.
    var xpBanked: Int = 0
    var rarity: String
    var scheduleType: String
    var targetCount: Int = 1
    var isAllOrNothing: Bool
    var approvalMode: String
    var descriptionText: String?
    var createdByRecordName: String
    // Hero Board claim state (V8) — mirrors of the Quest CK fields. A non-nil
    // claimer means the quest is off the board; nil on both means claimable.
    var claimedByProfileRecordName: String?
    var claimedAt: Date?
    var changeTag: String?
    var encodedSystemFields: Data?
    var sourceZoneName: String?
    var sourceZoneOwnerName: String?
    var sourceDatabaseScope: String?

    var approvalModeEnum: ApprovalMode? {
        ApprovalMode(rawValue: approvalMode)
    }

    var rarityEnum: QuestRarity? {
        // Rarity derived from XP at read time, falling back to raw string for legacy rows.
        if xpReward > 0 {
            return QuestRarity.from(xp: xpReward)
        }
        return QuestRarity(rawValue: rarity)
    }

    var scheduleTypeEnum: QuestSchedule? {
        QuestSchedule(rawValue: scheduleType)
    }

    func isScheduled(on date: Date, template: QuestTemplateCache?, payoutDay: PayoutDay) -> Bool {
        guard isActive,
              WeekMath.weekRange(starting: WeekMath.startOfWeek(for: date, payoutDay: payoutDay)).contains(weekOf)
        else {
            return false
        }

        guard scheduleTypeEnum == .specificDays else {
            return scheduleTypeEnum == .weeklyFlexible
        }

        return template?.specificDays?.contains(WeekMath.weekdayCode(for: date)) == true
    }

    init(recordName: String,
         familyRecordName: String,
         assigneeRecordName: String,
         templateRecordName: String,
         weekOf: Date,
         questName: String,
         isActive: Bool,
         goldReward: Double,
         xpReward: Int,
         rarity: String,
         scheduleType: String,
         targetCount: Int = 1,
         isAllOrNothing: Bool,
         approvalMode: String,
         descriptionText: String?,
         createdByRecordName: String,
         xpBanked: Int = 0,
         claimedByProfileRecordName: String? = nil,
         claimedAt: Date? = nil,
         changeTag: String? = nil,
         encodedSystemFields: Data? = nil,
         sourceZoneName: String? = nil,
         sourceZoneOwnerName: String? = nil,
         sourceDatabaseScope: String? = nil)
    {
        self.recordName = recordName
        self.familyRecordName = familyRecordName
        self.assigneeRecordName = assigneeRecordName
        self.templateRecordName = templateRecordName
        self.weekOf = weekOf
        self.questName = questName
        self.isActive = isActive
        self.goldReward = goldReward
        self.xpReward = xpReward
        self.xpBanked = xpBanked
        self.rarity = rarity
        self.scheduleType = scheduleType
        self.targetCount = max(1, targetCount)
        self.isAllOrNothing = isAllOrNothing
        self.approvalMode = approvalMode
        self.descriptionText = descriptionText
        self.createdByRecordName = createdByRecordName
        self.claimedByProfileRecordName = claimedByProfileRecordName
        self.claimedAt = claimedAt
        self.changeTag = changeTag
        self.encodedSystemFields = encodedSystemFields
        self.sourceZoneName = sourceZoneName
        self.sourceZoneOwnerName = sourceZoneOwnerName
        self.sourceDatabaseScope = sourceDatabaseScope
    }

    convenience init(from quest: Quest) {
        self.init(
            recordName: quest.id.recordName,
            familyRecordName: quest.family.recordID.recordName,
            assigneeRecordName: quest.assignee.recordID.recordName,
            templateRecordName: quest.template.recordID.recordName,
            weekOf: quest.weekOf,
            questName: quest.displayName,
            isActive: quest.active,
            goldReward: quest.goldReward,
            xpReward: quest.xpReward,
            rarity: quest.rarity.rawValue,
            scheduleType: quest.scheduleType.rawValue,
            targetCount: quest.targetCount,
            isAllOrNothing: quest.isAllOrNothing,
            approvalMode: quest.approvalMode.rawValue,
            descriptionText: quest.descriptionText,
            createdByRecordName: quest.createdBy.recordID.recordName,
            xpBanked: quest.xpBanked,
            claimedByProfileRecordName: quest.claimedByProfileRecordName,
            claimedAt: quest.claimedAt,
            changeTag: quest.changeTag,
            encodedSystemFields: quest.encodedSystemFields,
            sourceZoneName: quest.id.zoneID.zoneName,
            sourceZoneOwnerName: quest.id.zoneID.ownerName,
            sourceDatabaseScope: inferDatabaseScope(from: quest.id.zoneID)
        )
    }

    // MARK: - CacheMergeable

    func update(from quest: Quest, isServerSync: Bool = false) {
        familyRecordName = quest.family.recordID.recordName
        assigneeRecordName = quest.assignee.recordID.recordName
        templateRecordName = quest.template.recordID.recordName
        weekOf = quest.weekOf
        questName = quest.displayName
        isActive = quest.active
        goldReward = quest.goldReward
        xpReward = quest.xpReward
        xpBanked = quest.xpBanked
        sourceZoneName = quest.id.zoneID.zoneName
        sourceZoneOwnerName = quest.id.zoneID.ownerName
        sourceDatabaseScope = inferDatabaseScope(from: quest.id.zoneID)
        // `rarity` is intentionally NOT re-stamped: `rarityEnum` derives it from
        // `xpReward` at read time, so the stored string is only a legacy
        // fallback for rows without a meaningful xpReward.
        scheduleType = quest.scheduleType.rawValue
        isAllOrNothing = quest.isAllOrNothing
        approvalMode = quest.approvalMode.rawValue
        descriptionText = quest.descriptionText
        targetCount = max(1, quest.targetCount)
        createdByRecordName = quest.createdBy.recordID.recordName
        claimedByProfileRecordName = quest.claimedByProfileRecordName
        claimedAt = quest.claimedAt
        changeTag = quest.changeTag
        if isServerSync, quest.encodedSystemFields != nil {
            encodedSystemFields = quest.encodedSystemFields
        }
    }

    static func fetchDescriptor(familyRecordName: String?) -> FetchDescriptor<QuestCache> {
        if let familyRecordName {
            return FetchDescriptor<QuestCache>(predicate: #Predicate { $0.familyRecordName == familyRecordName })
        }
        return FetchDescriptor<QuestCache>()
    }

    static func fetchDescriptor(recordName: String) -> FetchDescriptor<QuestCache> {
        FetchDescriptor<QuestCache>(predicate: #Predicate { $0.recordName == recordName })
    }

    static func fetchDescriptor(recordName: String, familyRecordName: String) -> FetchDescriptor<QuestCache> {
        FetchDescriptor<QuestCache>(predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == familyRecordName })
    }
}
