import CloudKit
import Foundation

struct LedgerEntry: Identifiable, Equatable, Sendable {
    static let recordType: String = "LedgerEntry"

    let id: CKRecord.ID

    var profile: CKRecord.Reference

    var amount: Double

    var description: String
    var date: Date

    var source: String

    var family: CKRecord.Reference

    init(record: CKRecord) throws {
        guard record.recordType == Self.recordType else {
            throw CKDecodingError.unexpectedRecordType(expected: Self.recordType,
                                                       actual: record.recordType)
        }
        id = record.recordID

        guard let profile = record["profile"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("profile")
        }
        self.profile = profile

        guard let amount = record["amount"] as? Double else {
            throw CKDecodingError.missingField("amount")
        }
        self.amount = amount

        guard let description = record["description"] as? String else {
            throw CKDecodingError.missingField("description")
        }
        self.description = description

        guard let date = record["date"] as? Date else {
            throw CKDecodingError.missingField("date")
        }
        self.date = date

        guard let source = record["source"] as? String else {
            throw CKDecodingError.missingField("source")
        }
        self.source = source

        guard let family = record["family"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("family")
        }
        self.family = family
    }

    func toRecord() -> CKRecord {
        let record = CKRecord(recordType: Self.recordType, recordID: id)
        record["profile"] = profile as CKRecordValue
        record["amount"] = amount as CKRecordValue
        record["description"] = description as CKRecordValue
        record["date"] = date as CKRecordValue
        record["source"] = source as CKRecordValue
        record["family"] = family as CKRecordValue
        return record
    }

    init(profile: CKRecord.Reference,
         amount: Double,
         description: String,
         date: Date = Date(),
         source: String = "manual",
         family: CKRecord.Reference,
         id: CKRecord.ID = CKRecord.ID(recordName: UUID().uuidString))
    {
        self.id = id
        self.profile = profile
        self.amount = amount
        self.description = description
        self.date = date
        self.source = source
        self.family = family
    }
}
