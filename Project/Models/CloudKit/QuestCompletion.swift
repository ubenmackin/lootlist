import Foundation
import CloudKit

struct QuestCompletion: Identifiable, Equatable, Sendable {

    static let recordType: String = "QuestLog"

    let id: CKRecord.ID

    var quest: CKRecord.Reference

    var completedBy: CKRecord.Reference

    var completedDate: Date

    var verificationStatus: VerificationStatus

    var verifiedBy: CKRecord.Reference?

    var verifiedDate: Date?

    var weekOf: Date

    var family: CKRecord.Reference

    init(record: CKRecord) throws {
        guard record.recordType == Self.recordType else {
            throw CKDecodingError.unexpectedRecordType(expected: Self.recordType,
                                                        actual: record.recordType)
        }
        self.id = record.recordID

        guard let quest = record["quest"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("quest")
        }
        self.quest = quest

        guard let completedBy = record["completedBy"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("completedBy")
        }
        self.completedBy = completedBy

        guard let completedDate = record["completedDate"] as? Date else {
            throw CKDecodingError.missingField("completedDate")
        }
        self.completedDate = completedDate

        guard let verificationStatusRaw = record["verificationStatus"] as? String else {
            throw CKDecodingError.missingField("verificationStatus")
        }
        self.verificationStatus = VerificationStatus(rawValue: verificationStatusRaw) ?? .pending

        self.verifiedBy   = record["verifiedBy"]   as? CKRecord.Reference
        self.verifiedDate = record["verifiedDate"] as? Date

        guard let weekOf = record["weekOf"] as? Date else {
            throw CKDecodingError.missingField("weekOf")
        }
        self.weekOf = weekOf

        guard let family = record["family"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("family")
        }
        self.family = family
    }

    func toRecord() -> CKRecord {
        let record = CKRecord(recordType: Self.recordType, recordID: id)
        record["quest"]              = quest as CKRecordValue
        record["completedBy"]        = completedBy as CKRecordValue
        record["completedDate"]      = completedDate as CKRecordValue
        record["verificationStatus"] = verificationStatus.rawValue as CKRecordValue
        if let verifiedBy {
            record["verifiedBy"] = verifiedBy as CKRecordValue
        }
        if let verifiedDate {
            record["verifiedDate"] = verifiedDate as CKRecordValue
        }
        record["weekOf"]             = weekOf as CKRecordValue
        record["family"]             = family as CKRecordValue
        return record
    }

    init(quest: CKRecord.Reference,
         completedBy: CKRecord.Reference,
         approvalMode: ApprovalMode,
         weekOf: Date,
         family: CKRecord.Reference,
         id: CKRecord.ID = CKRecord.ID(recordName: UUID().uuidString)) {
        self.id = id
        self.quest = quest
        self.completedBy = completedBy
        self.completedDate = Date()
        self.verificationStatus = (approvalMode == .autoApprove)
            ? .autoApproved
            : .pending
        self.verifiedBy = nil
        self.verifiedDate = nil
        self.weekOf = weekOf
        self.family = family
    }
}
