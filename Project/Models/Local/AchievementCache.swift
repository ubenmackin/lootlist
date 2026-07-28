//
//  AchievementCache.swift
//  LootList
//
//  Created for Local-First SwiftData Architecture.
//

import Foundation
import SwiftData

@Model
final class AchievementCache {
    #Index<AchievementCache>([\.familyRecordName])

    @Attribute(.unique) var recordName: String
    var familyRecordName: String
    var name: String
    var achievementDescription: String
    var iconSystemName: String
    var category: String
    var requirementType: String
    var requirementValue: Int
    var changeTag: String?

    init(recordName: String,
         familyRecordName: String,
         name: String,
         achievementDescription: String,
         iconSystemName: String,
         category: String,
         requirementType: String,
         requirementValue: Int,
         changeTag: String? = nil)
    {
        self.recordName = recordName
        self.familyRecordName = familyRecordName
        self.name = name
        self.achievementDescription = achievementDescription
        self.iconSystemName = iconSystemName
        self.category = category
        self.requirementType = requirementType
        self.requirementValue = requirementValue
        self.changeTag = changeTag
    }

    convenience init(from achievement: Achievement) {
        self.init(
            recordName: achievement.id.recordName,
            familyRecordName: achievement.family.recordID.recordName,
            name: achievement.name,
            achievementDescription: achievement.description,
            iconSystemName: achievement.iconSystemName,
            category: achievement.category.rawValue,
            requirementType: achievement.requirementType.rawValue,
            requirementValue: achievement.requirementValue,
            changeTag: achievement.changeTag
        )
    }
}
