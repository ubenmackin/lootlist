import Foundation
import CloudKit

struct AllowancePeriod: Identifiable, Equatable, Sendable {

    static let recordType: String = "AllowancePeriod"

    let id: CKRecord.ID

    var weekOf: Date

    var profile: CKRecord.Reference

    var status: PayoutStatus
    var totalEarned: Double
    var questsCompleted: Int
    var questsTotal: Int

    var paidDate: Date?
    var paidAmount: Double?

    var family: CKRecord.Reference

    init(record: CKRecord) throws {
        guard record.recordType == Self.recordType else {
            throw CKDecodingError.unexpectedRecordType(expected: Self.recordType,
                                                        actual: record.recordType)
        }
        self.id = record.recordID

        guard let weekOf = record["weekOf"] as? Date else {
            throw CKDecodingError.missingField("weekOf")
        }
        self.weekOf = weekOf

        guard let profile = record["profile"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("profile")
        }
        self.profile = profile

        guard let statusRaw = record["status"] as? String,
              let status = PayoutStatus(rawValue: statusRaw) else {
            throw CKDecodingError.missingField("status")
        }
        self.status = status

        guard let totalEarned = record["totalEarned"] as? Double else {
            throw CKDecodingError.missingField("totalEarned")
        }
        self.totalEarned = totalEarned

        guard let questsCompleted = record["questsCompleted"] as? Int else {
            throw CKDecodingError.missingField("questsCompleted")
        }
        self.questsCompleted = questsCompleted

        guard let questsTotal = record["questsTotal"] as? Int else {
            throw CKDecodingError.missingField("questsTotal")
        }
        self.questsTotal = questsTotal

        self.paidDate   = record["paidDate"]   as? Date
        self.paidAmount = record["paidAmount"] as? Double

        guard let family = record["family"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("family")
        }
        self.family = family
    }

    func toRecord() -> CKRecord {
        let record = CKRecord(recordType: Self.recordType, recordID: id)
        record["weekOf"]          = weekOf as CKRecordValue
        record["profile"]         = profile as CKRecordValue
        record["status"]          = status.rawValue as CKRecordValue
        record["totalEarned"]     = totalEarned as CKRecordValue
        record["questsCompleted"] = questsCompleted as CKRecordValue
        record["questsTotal"]     = questsTotal as CKRecordValue
        if let paidDate {
            record["paidDate"] = paidDate as CKRecordValue
        }
        if let paidAmount {
            record["paidAmount"] = paidAmount as CKRecordValue
        }
        record["family"]          = family as CKRecordValue
        return record
    }

    init(weekOf: Date,
         profile: CKRecord.Reference,
         questsTotal: Int,
         family: CKRecord.Reference,
         id: CKRecord.ID = CKRecord.ID(recordName: UUID().uuidString)) {
        self.id = id
        self.weekOf = weekOf
        self.profile = profile
        self.status = .active
        self.totalEarned = 0
        self.questsCompleted = 0
        self.questsTotal = questsTotal
        self.paidDate = nil
        self.paidAmount = nil
        self.family = family
    }
}
