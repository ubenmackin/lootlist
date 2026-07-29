//
//  QuestCache.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation
import SwiftData

@Model
final class QuestCache: FamilyScopedCache {
    #Index<QuestCache>([\.familyRecordName], [\.assigneeRecordName], [\.weekOf])

    @Attribute(.unique) var recordName: String
    var familyRecordName: String
    var assigneeRecordName: String
    var templateRecordName: String
    var weekOf: Date
    var questName: String
    var isActive: Bool
    var goldReward: Double
    var xpReward: Int
    var rarity: String
    var scheduleType: String
    var isAllOrNothing: Bool
    var approvalMode: String
    var descriptionText: String?
    var createdByRecordName: String
    var changeTag: String?

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
         isAllOrNothing: Bool,
         approvalMode: String,
         descriptionText: String?,
         createdByRecordName: String,
         changeTag: String? = nil)
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
        self.rarity = rarity
        self.scheduleType = scheduleType
        self.isAllOrNothing = isAllOrNothing
        self.approvalMode = approvalMode
        self.descriptionText = descriptionText
        self.createdByRecordName = createdByRecordName
        self.changeTag = changeTag
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
            isAllOrNothing: quest.isAllOrNothing,
            approvalMode: quest.approvalMode.rawValue,
            descriptionText: quest.descriptionText,
            createdByRecordName: quest.createdBy.recordID.recordName,
            changeTag: quest.changeTag
        )
    }
}
