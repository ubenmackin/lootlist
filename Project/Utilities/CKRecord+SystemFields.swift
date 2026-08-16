//
//  CKRecord+SystemFields.swift
//  LootList
//
//  Created by Ben Mackin on 8/14/26.
//

import CloudKit
import Foundation

extension CKRecord {
    /// Encodes this record's system fields into serialized Data for local persistence.
    var encodedSystemFields: Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        encodeSystemFields(with: archiver)
        return archiver.encodedData
    }

    /// Reconstructs a `CKRecord` with its preserved system fields (including `recordChangeTag`,
    /// creation/modification dates, and record ID) from encoded system fields data.
    /// Falls back to constructing a fresh `CKRecord` if `systemFields` is nil or cannot be decoded.
    static func from(systemFields: Data?, fallbackType: String, fallbackID: CKRecord.ID) -> CKRecord {
        if let systemFields,
           let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: systemFields)
        {
            unarchiver.requiresSecureCoding = true
            if let record = CKRecord(coder: unarchiver) {
                return record
            }
        }
        return CKRecord(recordType: fallbackType, recordID: fallbackID)
    }
}
