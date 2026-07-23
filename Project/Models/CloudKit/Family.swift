import CloudKit
import Foundation

struct Family: Identifiable, Equatable, Sendable {
    static let recordType: String = "Family"

    let id: CKRecord.ID

    var name: String

    var createdBy: CKRecord.ID

    var createdAt: Date

    var inviteCode: String

    var payoutPolicy: PayoutPolicy

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

        guard let createdByID = record["createdBy"] as? String else {
            throw CKDecodingError.missingField("createdBy")
        }
        createdBy = CKRecord.ID(recordName: createdByID)

        guard let createdAt = record["createdAt"] as? Date else {
            throw CKDecodingError.missingField("createdAt")
        }
        self.createdAt = createdAt

        guard let inviteCode = record["inviteCode"] as? String else {
            throw CKDecodingError.missingField("inviteCode")
        }
        self.inviteCode = inviteCode

        if let rawPolicy = record["payoutPolicy"] as? String,
           let policy = PayoutPolicy(rawValue: rawPolicy)
        {
            payoutPolicy = policy
        } else {
            payoutPolicy = .perQuest
        }
    }

    func toRecord() -> CKRecord {
        let record = CKRecord(recordType: Self.recordType, recordID: id)
        record["name"] = name as CKRecordValue
        record["createdBy"] = createdBy.recordName as CKRecordValue
        record["createdAt"] = createdAt as CKRecordValue
        record["inviteCode"] = inviteCode as CKRecordValue
        record["payoutPolicy"] = payoutPolicy.rawValue as CKRecordValue
        return record
    }

    init(name: String,
         createdBy: CKRecord.ID,
         inviteCode: String,
         payoutPolicy: PayoutPolicy = .perQuest,
         id: CKRecord.ID = CKRecord.ID(recordName: UUID().uuidString))
    {
        self.id = id
        self.name = name
        self.createdBy = createdBy
        createdAt = Date()
        self.inviteCode = inviteCode
        self.payoutPolicy = payoutPolicy
    }
}

enum CKDecodingError: Error, Equatable, Sendable {
    case unexpectedRecordType(expected: String, actual: String)

    case missingField(String)
}
