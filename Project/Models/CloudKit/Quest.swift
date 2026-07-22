import Foundation
import CloudKit

struct Quest: Identifiable, Equatable, Sendable {

    static let recordType: String = "Quest"

    let id: CKRecord.ID

    var template: CKRecord.Reference

    var assignee: CKRecord.Reference

    var goldReward: Double
    var xpReward: Int
    var scheduleType: QuestSchedule

    var allOrNothingGroup: String?

    var approvalMode: ApprovalMode

    var active: Bool

    var weekOf: Date

    var createdBy: CKRecord.Reference

    var family: CKRecord.Reference

    init(record: CKRecord) throws {
        guard record.recordType == Self.recordType else {
            throw CKDecodingError.unexpectedRecordType(expected: Self.recordType,
                                                        actual: record.recordType)
        }
        self.id = record.recordID

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

        guard let scheduleRaw = record["scheduleType"] as? String,
              let scheduleType = QuestSchedule(rawValue: scheduleRaw) else {
            throw CKDecodingError.missingField("scheduleType")
        }
        self.scheduleType = scheduleType

        self.allOrNothingGroup = record["allOrNothingGroup"] as? String

        guard let approvalRaw = record["approvalMode"] as? String,
              let approvalMode = ApprovalMode(rawValue: approvalRaw) else {
            throw CKDecodingError.missingField("approvalMode")
        }
        self.approvalMode = approvalMode

        self.active = (record["active"] as? Bool) ?? false

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
    }

    func toRecord() -> CKRecord {
        let record = CKRecord(recordType: Self.recordType, recordID: id)
        record["template"]           = template as CKRecordValue
        record["assignee"]          = assignee as CKRecordValue
        record["goldReward"]        = goldReward as CKRecordValue
        record["xpReward"]          = xpReward as CKRecordValue
        record["scheduleType"]      = scheduleType.rawValue as CKRecordValue
        if let allOrNothingGroup {
            record["allOrNothingGroup"] = allOrNothingGroup as CKRecordValue
        }
        record["approvalMode"]      = approvalMode.rawValue as CKRecordValue
        record["active"]            = active as CKRecordValue
        record["weekOf"]            = weekOf as CKRecordValue
        record["createdBy"]         = createdBy as CKRecordValue
        record["family"]            = family as CKRecordValue
        return record
    }

    init(template: CKRecord.Reference,
         assignee: CKRecord.Reference,
         goldReward: Double,
         xpReward: Int,
         scheduleType: QuestSchedule,
         allOrNothingGroup: String? = nil,
         approvalMode: ApprovalMode = .autoApprove,
         weekOf: Date,
         createdBy: CKRecord.Reference,
         family: CKRecord.Reference,
         id: CKRecord.ID = CKRecord.ID(recordName: UUID().uuidString)) {
        self.id = id
        self.template = template
        self.assignee = assignee
        self.goldReward = goldReward
        self.xpReward = xpReward
        self.scheduleType = scheduleType
        self.allOrNothingGroup = allOrNothingGroup
        self.approvalMode = approvalMode
        self.active = true
        self.weekOf = weekOf
        self.createdBy = createdBy
        self.family = family
    }
}
