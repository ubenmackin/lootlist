//
//  AchievementCache.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import SwiftData

@Model
final class AchievementCache: FamilyScopedCache, CacheMergeable {
    typealias DomainModel = Achievement

    #Index<AchievementCache>([\.familyRecordName, \.recordName])

    var recordName: String
    var familyRecordName: String
    var name: String
    var achievementDescription: String
    var iconSystemName: String
    var category: String
    var requirementType: String
    var requirementValue: Int
    var changeTag: String?
    var encodedSystemFields: Data?
    var sourceZoneName: String?
    var sourceZoneOwnerName: String?
    var sourceDatabaseScope: String?

    var categoryEnum: AchievementCategory? {
        AchievementCategory(rawValue: category)
    }

    var requirementTypeEnum: AchievementRequirement? {
        AchievementRequirement(rawValue: requirementType)
    }

    init(recordName: String,
         familyRecordName: String,
         name: String,
         achievementDescription: String,
         iconSystemName: String,
         category: String,
         requirementType: String,
         requirementValue: Int,
         changeTag: String? = nil,
         encodedSystemFields: Data? = nil,
         sourceZoneName: String? = nil,
         sourceZoneOwnerName: String? = nil,
         sourceDatabaseScope: String? = nil)
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
        self.encodedSystemFields = encodedSystemFields
        self.sourceZoneName = sourceZoneName
        self.sourceZoneOwnerName = sourceZoneOwnerName
        self.sourceDatabaseScope = sourceDatabaseScope
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
            changeTag: achievement.changeTag,
            encodedSystemFields: achievement.encodedSystemFields,
            sourceZoneName: achievement.id.zoneID.zoneName,
            sourceZoneOwnerName: achievement.id.zoneID.ownerName,
            sourceDatabaseScope: inferDatabaseScope(from: achievement.id.zoneID)
        )
    }

    // MARK: - CacheMergeable

    func update(from achievement: Achievement, isServerSync: Bool = false) {
        familyRecordName = achievement.family.recordID.recordName
        name = achievement.name
        achievementDescription = achievement.description
        iconSystemName = achievement.iconSystemName
        category = achievement.category.rawValue
        requirementType = achievement.requirementType.rawValue
        requirementValue = achievement.requirementValue
        changeTag = achievement.changeTag
        sourceZoneName = achievement.id.zoneID.zoneName
        sourceZoneOwnerName = achievement.id.zoneID.ownerName
        sourceDatabaseScope = inferDatabaseScope(from: achievement.id.zoneID)
        if isServerSync, achievement.encodedSystemFields != nil {
            encodedSystemFields = achievement.encodedSystemFields
        }
    }

    static func fetchDescriptor(familyRecordName: String?) -> FetchDescriptor<AchievementCache> {
        if let familyRecordName {
            return FetchDescriptor<AchievementCache>(predicate: #Predicate { $0.familyRecordName == familyRecordName })
        }
        return FetchDescriptor<AchievementCache>()
    }

    static func fetchDescriptor(recordName: String) -> FetchDescriptor<AchievementCache> {
        FetchDescriptor<AchievementCache>(predicate: #Predicate { $0.recordName == recordName })
    }

    static func fetchDescriptor(recordName: String, familyRecordName: String) -> FetchDescriptor<AchievementCache> {
        FetchDescriptor<AchievementCache>(predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == familyRecordName })
    }
}
