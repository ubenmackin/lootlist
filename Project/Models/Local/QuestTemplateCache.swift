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
    var goldReward: Double
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
         goldReward: Double,
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
            createdByRecordName: template.createdBy.recordID.recordName,
            changeTag: template.changeTag,
            encodedSystemFields: template.encodedSystemFields,
            sourceZoneName: template.id.zoneID.zoneName,
            sourceZoneOwnerName: template.id.zoneID.ownerName,
            sourceDatabaseScope: inferDatabaseScope(from: template.id.zoneID)
        )
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
        changeTag = template.changeTag
        sourceZoneName = template.id.zoneID.zoneName
        sourceZoneOwnerName = template.id.zoneID.ownerName
        sourceDatabaseScope = inferDatabaseScope(from: template.id.zoneID)
        if isServerSync, template.encodedSystemFields != nil {
            encodedSystemFields = template.encodedSystemFields
        }
    }

    static func fetchDescriptor(familyRecordName: String?) -> FetchDescriptor<QuestTemplateCache> {
        if let familyRecordName {
            return FetchDescriptor<QuestTemplateCache>(predicate: #Predicate { $0.familyRecordName == familyRecordName })
        }
        return FetchDescriptor<QuestTemplateCache>()
    }

    static func fetchDescriptor(recordName: String) -> FetchDescriptor<QuestTemplateCache> {
        FetchDescriptor<QuestTemplateCache>(predicate: #Predicate { $0.recordName == recordName })
    }

    static func fetchDescriptor(recordName: String, familyRecordName: String) -> FetchDescriptor<QuestTemplateCache> {
        FetchDescriptor<QuestTemplateCache>(predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == familyRecordName })
    }
}
