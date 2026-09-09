//
//  QuestTemplateCache.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import SwiftData

@Model
final class QuestTemplateCache: FamilyScopedCache, CacheMergeable {
    typealias DomainModel = QuestTemplate

    #Index<QuestTemplateCache>([\.familyRecordName, \.recordName])

    var recordName: String
    var familyRecordName: String
    var name: String
    var isActive: Bool
    /// Whole pennies — mirrors `QuestTemplate.defaultGold` with legacy prefix.
    var goldReward: Int64
    var xpReward: Int
    var rarity: String
    var specificDays: [String]?
    var targetCount: Int = 1
    var templateDescription: String
    var scheduleType: String
    var isAllOrNothing: Bool
    var approvalMode: String
    var createdByRecordName: String
    var changeTag: String?
    var encodedSystemFields: Data?
    var sourceZoneName: String?
    var sourceZoneOwnerName: String?
    var sourceDatabaseScope: String?

    var scheduleTypeEnum: QuestSchedule? {
        QuestSchedule(rawValue: scheduleType)
    }

    var rarityEnum: QuestRarity? {
        QuestRarity(rawValue: rarity)
    }

    var approvalModeEnum: ApprovalMode? {
        ApprovalMode(rawValue: approvalMode)
    }

    init(recordName: String,
         familyRecordName: String,
         name: String,
         isActive: Bool,
         goldReward: Int64,
         xpReward: Int,
         rarity: String,
         specificDays: [String]?,
         targetCount: Int = 1,
         templateDescription: String,
         scheduleType: String,
         isAllOrNothing: Bool,
         approvalMode: String,
         createdByRecordName: String,
         changeTag: String? = nil,
         encodedSystemFields: Data? = nil,
         sourceZoneName: String? = nil,
         sourceZoneOwnerName: String? = nil,
         sourceDatabaseScope: String? = nil)
    {
        self.recordName = recordName
        self.familyRecordName = familyRecordName
        self.name = name
        self.isActive = isActive
        self.goldReward = goldReward
        self.xpReward = xpReward
        self.rarity = rarity
        self.specificDays = specificDays
        self.targetCount = max(1, targetCount)
        self.templateDescription = templateDescription
        self.scheduleType = scheduleType
        self.isAllOrNothing = isAllOrNothing
        self.approvalMode = approvalMode
        self.createdByRecordName = createdByRecordName
        self.changeTag = changeTag
        self.encodedSystemFields = encodedSystemFields
        self.sourceZoneName = sourceZoneName
        self.sourceZoneOwnerName = sourceZoneOwnerName
        self.sourceDatabaseScope = sourceDatabaseScope
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
            targetCount: template.targetCount,
            templateDescription: template.description,
            scheduleType: template.scheduleType.rawValue,
            isAllOrNothing: template.isAllOrNothing,
            approvalMode: template.approvalMode.rawValue,
            createdByRecordName: template.createdBy.recordID.recordName
        )
        applySystemFields(from: template)
    }

    // MARK: - CacheMergeable

    func update(from template: QuestTemplate, isServerSync: Bool = false) {
        familyRecordName = template.family.recordID.recordName
        name = template.name
        isActive = template.isActive
        goldReward = template.defaultGold
        xpReward = template.xpReward
        rarity = template.rarity.rawValue
        specificDays = template.specificDays.isEmpty ? nil : template.specificDays
        templateDescription = template.description
        targetCount = max(1, template.targetCount)
        scheduleType = template.scheduleType.rawValue
        isAllOrNothing = template.isAllOrNothing
        approvalMode = template.approvalMode.rawValue
        createdByRecordName = template.createdBy.recordID.recordName
        applySystemFields(from: template, isServerSync: isServerSync)
    }

    static func fetchDescriptor(familyRecordName: String?) -> FetchDescriptor<QuestTemplateCache> {
        if let familyRecordName, !familyRecordName.isEmpty {
            return FetchDescriptor<QuestTemplateCache>(predicate: #Predicate { $0.familyRecordName == familyRecordName })
        }
        // WHY fail-closed: nil/empty scope must match zero rows, never the whole table.
        return FetchDescriptor<QuestTemplateCache>(predicate: #Predicate { $0.familyRecordName == "" })
    }

    static func fetchDescriptor(recordName: String, familyRecordName: String) -> FetchDescriptor<QuestTemplateCache> {
        FetchDescriptor<QuestTemplateCache>(predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == familyRecordName })
    }

    // MARK: - Family Predicates

    /// WHY single source: views share the family isolation boundary so store filtering never drifts.
    static func familyPredicate(familyRecordName: String) -> Predicate<QuestTemplateCache> {
        let targetFamily = familyRecordName
        return #Predicate<QuestTemplateCache> { $0.familyRecordName == targetFamily }
    }

    /// WHY separate: boards list active templates only while managers audit the full bank.
    static func activeFamilyPredicate(familyRecordName: String) -> Predicate<QuestTemplateCache> {
        let targetFamily = familyRecordName
        return #Predicate<QuestTemplateCache> { $0.familyRecordName == targetFamily && $0.isActive == true }
    }

    /// WHY single source: single-row reads stay index-bound on the composite key.
    static func recordPredicate(recordName: String, familyRecordName: String) -> Predicate<QuestTemplateCache> {
        let targetRecord = recordName
        let targetFamily = familyRecordName
        return #Predicate<QuestTemplateCache> {
            $0.familyRecordName == targetFamily && $0.recordName == targetRecord
        }
    }

    /// WHY fail-closed: empty scope returns zero rows via the index, never an unscoped scan.
    static func emptyPredicate() -> Predicate<QuestTemplateCache> {
        #Predicate<QuestTemplateCache> { $0.familyRecordName == "__empty__" }
    }
}
