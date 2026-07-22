import Foundation
import CloudKit

struct Family: Identifiable, Equatable, Sendable {

    static let recordType: String = "Family"

    let id: CKRecord.ID

    var name: String

    var createdBy: CKRecord.ID

    var createdAt: Date

    var inviteCode: String

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

        guard let createdByID = record["createdBy"] as? String else {
            throw CKDecodingError.missingField("createdBy")
        }
        self.createdBy = CKRecord.ID(recordName: createdByID)

        guard let createdAt = record["createdAt"] as? Date else {
            throw CKDecodingError.missingField("createdAt")
        }
        self.createdAt = createdAt

        guard let inviteCode = record["inviteCode"] as? String else {
            throw CKDecodingError.missingField("inviteCode")
        }
        self.inviteCode = inviteCode
    }

    func toRecord() -> CKRecord {
        let record = CKRecord(recordType: Self.recordType, recordID: id)
        record["name"]       = name as CKRecordValue
        record["createdBy"]  = createdBy.recordName as CKRecordValue
        record["createdAt"]  = createdAt as CKRecordValue
        record["inviteCode"] = inviteCode as CKRecordValue
        return record
    }

    init(name: String, createdBy: CKRecord.ID, inviteCode: String,
         id: CKRecord.ID = CKRecord.ID(recordName: UUID().uuidString)) {
        self.id = id
        self.name = name
        self.createdBy = createdBy
        self.createdAt = Date()
        self.inviteCode = inviteCode
    }
}

enum CKDecodingError: Error, Equatable, Sendable {

    case unexpectedRecordType(expected: String, actual: String)

    case missingField(String)
}
