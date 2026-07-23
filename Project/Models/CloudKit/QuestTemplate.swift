import CloudKit
import Foundation

struct QuestTemplate: Identifiable, Equatable, Hashable, Sendable {
    static let recordType: String = "QuestTemplate"

    let id: CKRecord.ID

    var name: String
    var description: String
    var defaultGold: Double
    var xpReward: Int
    var rarity: QuestRarity {
        QuestRarity.from(xp: xpReward)
    }
    var scheduleType: QuestSchedule

    var specificDays: [String]

    var isAllOrNothing: Bool

    var approvalMode: ApprovalMode

    var createdBy: CKRecord.Reference

    var family: CKRecord.Reference

    var isActive: Bool

    init(record: CKRecord) throws {
        guard record.recordType == Self.recordType else {
            throw CKDecodingError.unexpectedRecordType(expected: Self.recordType,
                                                       actual: record.recordType)
        }
        id = record.recordID

        guard let name = record["name"] as? String else {
            throw CKDecodingError.missingField("name")
        }
        self.name = name

        guard let description = record["description"] as? String else {
            throw CKDecodingError.missingField("description")
        }
        self.description = description

        guard let defaultGold = record["defaultGold"] as? Double else {
            throw CKDecodingError.missingField("defaultGold")
        }
        self.defaultGold = defaultGold

        guard let xpReward = record["xpReward"] as? Int else {
            throw CKDecodingError.missingField("xpReward")
        }
        self.xpReward = xpReward

        let scheduleRaw = (record["scheduleType"] as? String) ?? QuestSchedule.weeklyFlexible.rawValue
        self.scheduleType = QuestSchedule(rawValue: scheduleRaw) ?? .weeklyFlexible

        specificDays = (record["specificDays"] as? [String]) ?? []

        isAllOrNothing = (record["isAllOrNothing"] as? Bool) ?? false

        guard let approvalRaw = record["approvalMode"] as? String,
              let approvalMode = ApprovalMode(rawValue: approvalRaw)
        else {
            throw CKDecodingError.missingField("approvalMode")
        }
        self.approvalMode = approvalMode

        guard let createdBy = record["createdBy"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("createdBy")
        }
        self.createdBy = createdBy

        guard let family = record["family"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("family")
        }
        self.family = family

        isActive = (record["isActive"] as? Bool) ?? false
    }

    func toRecord() -> CKRecord {
        let record = CKRecord(recordType: Self.recordType, recordID: id)
        record["name"] = name as CKRecordValue
        record["description"] = description as CKRecordValue
        record["defaultGold"] = defaultGold as CKRecordValue
        record["xpReward"] = xpReward as CKRecordValue
        record["scheduleType"] = scheduleType.rawValue as CKRecordValue
        record["specificDays"] = specificDays as CKRecordValue
        record["isAllOrNothing"] = isAllOrNothing as CKRecordValue
        record["approvalMode"] = approvalMode.rawValue as CKRecordValue
        record["createdBy"] = createdBy as CKRecordValue
        record["family"] = family as CKRecordValue
        record["isActive"] = isActive as CKRecordValue
        return record
    }

    init(name: String,
         description: String,
         defaultGold: Double,
         xpReward: Int,
         scheduleType: QuestSchedule,
         specificDays: [String] = [],
         isAllOrNothing: Bool = false,
         approvalMode: ApprovalMode = .autoApprove,
         createdBy: CKRecord.Reference,
         family: CKRecord.Reference,
         isActive: Bool = true,
         id: CKRecord.ID = CKRecord.ID(recordName: UUID().uuidString))
    {
        self.id = id
        self.name = name
        self.description = description
        self.defaultGold = defaultGold
        self.xpReward = xpReward
        self.scheduleType = scheduleType
        self.specificDays = specificDays
        self.isAllOrNothing = isAllOrNothing
        self.approvalMode = approvalMode
        self.createdBy = createdBy
        self.family = family
        self.isActive = isActive
    }
}
