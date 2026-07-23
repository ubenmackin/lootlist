import CloudKit
import Foundation

struct Quest: Identifiable, Equatable, Sendable {
    static let recordType: String = "Quest"

    let id: CKRecord.ID

    var template: CKRecord.Reference

    var assignee: CKRecord.Reference

    var goldReward: Double
    var xpReward: Int
    var rarity: QuestRarity {
        QuestRarity.from(xp: xpReward)
    }
    var scheduleType: QuestSchedule

    var isAllOrNothing: Bool

    var approvalMode: ApprovalMode

    var active: Bool

    var weekOf: Date

    var createdBy: CKRecord.Reference

    var family: CKRecord.Reference

    var name: String?
    var descriptionText: String?

    var displayName: String {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            return name
        }
        let templateID = template.recordID.recordName
        if templateID.count > 6 {
            return "Quest \(templateID.suffix(6))"
        }
        return "Quest \(templateID)"
    }

    var displayDescription: String {
        descriptionText ?? ""
    }

    init(record: CKRecord) throws {
        guard record.recordType == Self.recordType else {
            throw CKDecodingError.unexpectedRecordType(expected: Self.recordType,
                                                       actual: record.recordType)
        }
        id = record.recordID

        guard let template = record["template"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("template")
        }
        self.template = template

        guard let assignee = record["assignee"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("assignee")
        }
        self.assignee = assignee

        guard let goldReward = record["goldReward"] as? Double else {
            throw CKDecodingError.missingField("goldReward")
        }
        self.goldReward = goldReward

        guard let xpReward = record["xpReward"] as? Int else {
            throw CKDecodingError.missingField("xpReward")
        }
        self.xpReward = xpReward

        let scheduleRaw = (record["scheduleType"] as? String) ?? QuestSchedule.weeklyFlexible.rawValue
        self.scheduleType = QuestSchedule(rawValue: scheduleRaw) ?? .weeklyFlexible

        isAllOrNothing = (record["isAllOrNothing"] as? Bool) ?? false

        guard let approvalRaw = record["approvalMode"] as? String,
              let approvalMode = ApprovalMode(rawValue: approvalRaw)
        else {
            throw CKDecodingError.missingField("approvalMode")
        }
        self.approvalMode = approvalMode

        active = (record["active"] as? Bool) ?? false

        guard let weekOf = record["weekOf"] as? Date else {
            throw CKDecodingError.missingField("weekOf")
        }
        self.weekOf = weekOf

        guard let createdBy = record["createdBy"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("createdBy")
        }
        self.createdBy = createdBy

        guard let family = record["family"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("family")
        }
        self.family = family

        name = record["name"] as? String
        descriptionText = record["descriptionText"] as? String
    }

    func toRecord() -> CKRecord {
        let record = CKRecord(recordType: Self.recordType, recordID: id)
        record["template"] = template as CKRecordValue
        record["assignee"] = assignee as CKRecordValue
        record["goldReward"] = goldReward as CKRecordValue
        record["xpReward"] = xpReward as CKRecordValue
        record["scheduleType"] = scheduleType.rawValue as CKRecordValue
        record["isAllOrNothing"] = isAllOrNothing as CKRecordValue
        record["approvalMode"] = approvalMode.rawValue as CKRecordValue
        record["active"] = active as CKRecordValue
        record["weekOf"] = weekOf as CKRecordValue
        record["createdBy"] = createdBy as CKRecordValue
        record["family"] = family as CKRecordValue
        if let name {
            record["name"] = name as CKRecordValue
        }
        if let descriptionText {
            record["descriptionText"] = descriptionText as CKRecordValue
        }
        return record
    }

    init(template: CKRecord.Reference,
         assignee: CKRecord.Reference,
         goldReward: Double,
         xpReward: Int,
         scheduleType: QuestSchedule,
         isAllOrNothing: Bool = false,
         approvalMode: ApprovalMode = .autoApprove,
         weekOf: Date,
         createdBy: CKRecord.Reference,
         family: CKRecord.Reference,
         name: String? = nil,
         descriptionText: String? = nil,
         id: CKRecord.ID = CKRecord.ID(recordName: UUID().uuidString))
    {
        self.id = id
        self.template = template
        self.assignee = assignee
        self.goldReward = goldReward
        self.xpReward = xpReward
        self.scheduleType = scheduleType
        self.isAllOrNothing = isAllOrNothing
        self.approvalMode = approvalMode
        active = true
        self.weekOf = weekOf
        self.createdBy = createdBy
        self.family = family
        self.name = name
        self.descriptionText = descriptionText
    }
}
