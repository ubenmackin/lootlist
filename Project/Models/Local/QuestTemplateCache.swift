//
//  QuestTemplateCache.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation
import SwiftData

@Model
final class QuestTemplateCache: FamilyScopedCache {
    #Index<QuestTemplateCache>([\.familyRecordName])

    @Attribute(.unique) var recordName: String
    var familyRecordName: String
    var name: String
    var isActive: Bool
    var goldReward: Double
    var xpReward: Int
    var rarity: String
    var specificDays: [String]?
    var templateDescription: String
    var scheduleType: String
    var isAllOrNothing: Bool
    var approvalMode: String
    var createdByRecordName: String
    var changeTag: String?

    init(recordName: String,
         familyRecordName: String,
         name: String,
         isActive: Bool,
         goldReward: Double,
         xpReward: Int,
         rarity: String,
         specificDays: [String]?,
         templateDescription: String,
         scheduleType: String,
         isAllOrNothing: Bool,
         approvalMode: String,
         createdByRecordName: String,
         changeTag: String? = nil)
    {
        self.recordName = recordName
        self.familyRecordName = familyRecordName
        self.name = name
        self.isActive = isActive
        self.goldReward = goldReward
        self.xpReward = xpReward
        self.rarity = rarity
        self.specificDays = specificDays
        self.templateDescription = templateDescription
        self.scheduleType = scheduleType
        self.isAllOrNothing = isAllOrNothing
        self.approvalMode = approvalMode
        self.createdByRecordName = createdByRecordName
        self.changeTag = changeTag
    }

    convenience init(from template: QuestTemplate) {
        self.init(
            recordName: template.id.recordName,
            familyRecordName: template.family.recordID.recordName,
            name: template.name,
            isActive: template.isActive,
            goldReward: template.defaultGold,
            xpReward: template.xpReward,
            rarity: template.rarity.rawValue,
            specificDays: template.specificDays.isEmpty ? nil : template.specificDays,
            templateDescription: template.description,
            scheduleType: template.scheduleType.rawValue,
            isAllOrNothing: template.isAllOrNothing,
            approvalMode: template.approvalMode.rawValue,
            createdByRecordName: template.createdBy.recordID.recordName,
            changeTag: template.changeTag
        )
    }
}
