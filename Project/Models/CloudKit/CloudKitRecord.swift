import CloudKit
import Foundation

protocol CloudKitRecord {
    static var recordType: String { get }

    init(record: CKRecord) throws

    func toRecord() -> CKRecord
}

extension Family: CloudKitRecord {}
extension Profile: CloudKitRecord {}
extension QuestTemplate: CloudKitRecord {}
extension Quest: CloudKitRecord {}
extension QuestCompletion: CloudKitRecord {}
extension AllowancePeriod: CloudKitRecord {}
extension LedgerEntry: CloudKitRecord {}
extension Achievement: CloudKitRecord {}
extension ProfileAchievement: CloudKitRecord {}
extension NotificationPreference: CloudKitRecord {}

enum CKDecodingError: Error, Equatable, Sendable {
    case unexpectedRecordType(expected: String, actual: String)

    case missingField(String)
}
