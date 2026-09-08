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
            requirementValue: achievement.requirementValue
        )
        applySystemFields(from: achievement)
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
        applySystemFields(from: achievement, isServerSync: isServerSync)
    }

    static func fetchDescriptor(familyRecordName: String?) -> FetchDescriptor<AchievementCache> {
        if let familyRecordName, !familyRecordName.isEmpty {
            return FetchDescriptor<AchievementCache>(predicate: #Predicate { $0.familyRecordName == familyRecordName })
        }
        // WHY fail-closed: nil/empty scope must match zero rows, never the whole table.
        return FetchDescriptor<AchievementCache>(predicate: #Predicate { $0.familyRecordName == "" })
    }

    static func fetchDescriptor(recordName: String, familyRecordName: String) -> FetchDescriptor<AchievementCache> {
        FetchDescriptor<AchievementCache>(predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == familyRecordName })
    }

    // MARK: - Family Predicates

    /// WHY single source: views share the family isolation boundary so store filtering never drifts.
    static func familyPredicate(familyRecordName: String) -> Predicate<AchievementCache> {
        let targetFamily = familyRecordName
        return #Predicate<AchievementCache> { $0.familyRecordName == targetFamily }
    }
}
