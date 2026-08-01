//
//  CloudKitRecord.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation

protocol CloudKitRecord {
    static var recordType: String { get }

    init(record: CKRecord) throws

    func toRecord() -> CKRecord
}

extension CKRecord {
    func bool(forKey key: String, default defaultValue: Bool = false) -> Bool {
        if let boolVal = self[key] as? Bool {
            return boolVal
        }
        if let numVal = self[key] as? NSNumber {
            return numVal.boolValue
        }
        return defaultValue
    }

    func extract<T>(_ key: String) throws -> T {
        guard let value = self[key] as? T else {
            throw CKDecodingError.missingField(key)
        }
        return value
    }

    func extractOptional<T>(_ key: String) -> T? {
        self[key] as? T
    }
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
