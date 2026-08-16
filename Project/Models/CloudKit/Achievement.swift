//
//  Achievement.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation

struct Achievement: Identifiable, Equatable, Sendable {
    static let recordType: String = "Achievement"

    let id: CKRecord.ID

    /// Server-owned CloudKit change tag captured on read for cache-staleness
    /// checks. Not authored locally — `toRecord()` does not stamp this field.
    var changeTag: String?

    /// Serialized CloudKit system fields (metadata, change tag, dates) to avoid
    /// conflict loops when sending updates via CKSyncEngine.
    var encodedSystemFields: Data?

    var name: String
    var description: String
    var iconSystemName: String

    var category: AchievementCategory

    var requirementType: AchievementRequirement

    var requirementValue: Int

    var family: CKRecord.Reference

    init(
        id: CKRecord.ID,
        name: String,
        description: String,
        iconSystemName: String,
        category: AchievementCategory,
        requirementType: AchievementRequirement,
        requirementValue: Int,
        family: CKRecord.Reference
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.iconSystemName = iconSystemName
        self.category = category
        self.requirementType = requirementType
        self.requirementValue = requirementValue
        self.family = family
    }

    init(record: CKRecord) throws {
        guard record.recordType == Self.recordType else {
            throw CKDecodingError.unexpectedRecordType(expected: Self.recordType,
                                                       actual: record.recordType)
        }
        id = record.recordID
        changeTag = record.recordChangeTag
        encodedSystemFields = record.encodedSystemFields

        name = try record.extract("name")
        description = try record.extract("description")
        iconSystemName = try record.extract("iconSystemName")

        guard let categoryRaw: String = record.extractOptional("category"),
              let category = AchievementCategory(rawValue: categoryRaw)
        else {
            throw CKDecodingError.missingField("category")
        }
        self.category = category

        guard let requirementTypeRaw: String = record.extractOptional("requirementType"),
              let requirementType = AchievementRequirement(rawValue: requirementTypeRaw)
        else {
            throw CKDecodingError.missingField("requirementType")
        }
        self.requirementType = requirementType

        requirementValue = try record.extract("requirementValue")

        guard let family = record["family"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("family")
        }
        self.family = family
    }

    func toRecord() -> CKRecord {
        let record = CKRecord.from(systemFields: encodedSystemFields, fallbackType: Self.recordType, fallbackID: id)
        record["name"] = name as CKRecordValue
        record["description"] = description as CKRecordValue
        record["iconSystemName"] = iconSystemName as CKRecordValue
        record["category"] = category.rawValue as CKRecordValue
        record["requirementType"] = requirementType.rawValue as CKRecordValue
        record["requirementValue"] = requirementValue as CKRecordValue
        record["family"] = family as CKRecordValue
        return record
    }

    init(name: String,
         description: String,
         iconSystemName: String,
         category: AchievementCategory,
         requirementType: AchievementRequirement,
         requirementValue: Int,
         family: CKRecord.Reference,
         id: CKRecord.ID = CKRecord.ID(recordName: UUID().uuidString))
    {
        self.id = id
        self.name = name
        self.description = description
        self.iconSystemName = iconSystemName
        self.category = category
        self.requirementType = requirementType
        self.requirementValue = requirementValue
        self.family = family
    }
}
