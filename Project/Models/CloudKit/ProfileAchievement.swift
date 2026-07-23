import CloudKit
import Foundation

struct ProfileAchievement: Identifiable, Equatable, Sendable {
    static let recordType: String = "ProfileAchievement"

    let id: CKRecord.ID

    var achievement: CKRecord.Reference

    var profile: CKRecord.Reference

    var earnedDate: Date

    var family: CKRecord.Reference

    init(record: CKRecord) throws {
        guard record.recordType == Self.recordType else {
            throw CKDecodingError.unexpectedRecordType(expected: Self.recordType,
                                                       actual: record.recordType)
        }
        id = record.recordID

        guard let achievement = record["achievement"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("achievement")
        }
        self.achievement = achievement

        guard let profile = record["profile"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("profile")
        }
        self.profile = profile

        guard let earnedDate = record["earnedDate"] as? Date else {
            throw CKDecodingError.missingField("earnedDate")
        }
        self.earnedDate = earnedDate

        guard let family = record["family"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("family")
        }
        self.family = family
    }

    func toRecord() -> CKRecord {
        let record = CKRecord(recordType: Self.recordType, recordID: id)
        record["achievement"] = achievement as CKRecordValue
        record["profile"] = profile as CKRecordValue
        record["earnedDate"] = earnedDate as CKRecordValue
        record["family"] = family as CKRecordValue
        return record
    }

    init(achievement: CKRecord.Reference,
         profile: CKRecord.Reference,
         earnedDate: Date = Date(),
         family: CKRecord.Reference,
         id: CKRecord.ID = CKRecord.ID(recordName: UUID().uuidString))
    {
        self.id = id
        self.achievement = achievement
        self.profile = profile
        self.earnedDate = earnedDate
        self.family = family
    }
}
