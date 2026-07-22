import Foundation
import CloudKit

struct QuestTemplate: Identifiable, Equatable, Sendable {

    static let recordType: String = "QuestTemplate"

    let id: CKRecord.ID

    var name: String
    var description: String
    var defaultGold: Double
    var xpReward: Int
    var scheduleType: QuestSchedule

    var specificDays: [String]

    var approvalMode: ApprovalMode

    var createdBy: CKRecord.Reference

    var family: CKRecord.Reference

    var isActive: Bool

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

        guard let defaultGold = record["defaultGold"] as? Double else {
            throw CKDecodingError.missingField("defaultGold")
        }
        self.defaultGold = defaultGold

        guard let xpReward = record["xpReward"] as? Int else {
            throw CKDecodingError.missingField("xpReward")
        }
        self.xpReward = xpReward

        guard let scheduleRaw = record["scheduleType"] as? String,
              let scheduleType = QuestSchedule(rawValue: scheduleRaw) else {
            throw CKDecodingError.missingField("scheduleType")
        }
        self.scheduleType = scheduleType

        self.specificDays = (record["specificDays"] as? [String]) ?? []

        guard let approvalRaw = record["approvalMode"] as? String,
              let approvalMode = ApprovalMode(rawValue: approvalRaw) else {
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

        self.isActive = (record["isActive"] as? Bool) ?? false
    }

    func toRecord() -> CKRecord {
        let record = CKRecord(recordType: Self.recordType, recordID: id)
        record["name"]          = name as CKRecordValue
        record["description"]   = description as CKRecordValue
        record["defaultGold"]   = defaultGold as CKRecordValue
        record["xpReward"]      = xpReward as CKRecordValue
        record["scheduleType"]  = scheduleType.rawValue as CKRecordValue
        record["specificDays"]  = specificDays as CKRecordValue
        record["approvalMode"]  = approvalMode.rawValue as CKRecordValue
        record["createdBy"]     = createdBy as CKRecordValue
        record["family"]       = family as CKRecordValue
        record["isActive"]     = isActive as CKRecordValue
        return record
    }

    init(name: String,
         description: String,
         defaultGold: Double,
         xpReward: Int,
         scheduleType: QuestSchedule,
         specificDays: [String] = [],
         approvalMode: ApprovalMode = .autoApprove,
         createdBy: CKRecord.Reference,
         family: CKRecord.Reference,
         id: CKRecord.ID = CKRecord.ID(recordName: UUID().uuidString)) {
        self.id = id
        self.name = name
        self.description = description
        self.defaultGold = defaultGold
        self.xpReward = xpReward
        self.scheduleType = scheduleType
        self.specificDays = specificDays
        self.approvalMode = approvalMode
        self.createdBy = createdBy
        self.family = family
        self.isActive = true
    }
}

extension QuestTemplate: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: QuestTemplate, rhs: QuestTemplate) -> Bool { lhs.id == rhs.id }
}
