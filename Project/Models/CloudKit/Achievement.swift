import Foundation
import CloudKit

struct Achievement: Identifiable, Equatable, Sendable {

    static let recordType: String = "Achievement"

    let id: CKRecord.ID

    var name: String
    var description: String
    var iconSystemName: String

    var category: String

    var requirementType: String

    var requirementValue: Int

    var family: CKRecord.Reference

    init(record: CKRecord) throws {
        guard record.recordType == Self.recordType else {
            throw CKDecodingError.unexpectedRecordType(expected: Self.recordType,
                                                        actual: record.recordType)
        }
        self.id = record.recordID

        guard let name = record["name"] as? String else {
            throw CKDecodingError.missingField("name")
        }
        self.name = name

        guard let description = record["description"] as? String else {
            throw CKDecodingError.missingField("description")
        }
        self.description = description

        guard let iconSystemName = record["iconSystemName"] as? String else {
            throw CKDecodingError.missingField("iconSystemName")
        }
        self.iconSystemName = iconSystemName

        guard let category = record["category"] as? String else {
            throw CKDecodingError.missingField("category")
        }
        self.category = category

        guard let requirementType = record["requirementType"] as? String else {
            throw CKDecodingError.missingField("requirementType")
        }
        self.requirementType = requirementType

        guard let requirementValue = record["requirementValue"] as? Int else {
            throw CKDecodingError.missingField("requirementValue")
        }
        self.requirementValue = requirementValue

        guard let family = record["family"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("family")
        }
        self.family = family
    }

    func toRecord() -> CKRecord {
        let record = CKRecord(recordType: Self.recordType, recordID: id)
        record["name"]             = name as CKRecordValue
        record["description"]      = description as CKRecordValue
        record["iconSystemName"]   = iconSystemName as CKRecordValue
        record["category"]         = category as CKRecordValue
        record["requirementType"]  = requirementType as CKRecordValue
        record["requirementValue"] = requirementValue as CKRecordValue
        record["family"]           = family as CKRecordValue
        return record
    }

    init(name: String,
         description: String,
         iconSystemName: String,
         category: String,
         requirementType: String,
         requirementValue: Int,
         family: CKRecord.Reference,
         id: CKRecord.ID = CKRecord.ID(recordName: UUID().uuidString)) {
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
