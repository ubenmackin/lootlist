//
//  ScopedRecordIdentity.swift
//  LootList
//
//  Created by Ben Mackin on 8/13/26.
//

import CloudKit
import Foundation

/// Composite identity for a CloudKit record scoped to a specific database, zone,
/// and family. Prevents cross-family/cross-zone record collisions in local cache
/// operations and during sync conflict resolution.
struct ScopedRecordIdentity: Hashable, Sendable {
    let databaseScope: CKDatabase.Scope
    let zoneID: CKRecordZone.ID
    let recordID: CKRecord.ID
    let familyRecordName: String?

    init(
        databaseScope: CKDatabase.Scope,
        zoneID: CKRecordZone.ID,
        recordID: CKRecord.ID,
        familyRecordName: String?
    ) {
        self.databaseScope = databaseScope
        self.zoneID = zoneID
        self.recordID = recordID
        self.familyRecordName = familyRecordName
    }

    init(from record: CKRecord, databaseScope: CKDatabase.Scope, familyRecordName: String?) {
        self.databaseScope = databaseScope
        self.zoneID = record.recordID.zoneID
        self.recordID = record.recordID
        self.familyRecordName = familyRecordName
    }

    var recordName: String {
        recordID.recordName
    }

    var databaseScopeString: String {
        switch databaseScope {
        case .private: "private"
        case .shared: "shared"
        case .public: "public"
        @unknown default: "unknown"
        }
    }

    /// Validates that this identity matches the expected active scope. Throws if there's a mismatch.
    func validateScope(against activeScope: ScopedRecordIdentity) throws {
        try validateScope(
            expectedFamily: activeScope.familyRecordName,
            expectedZone: activeScope.zoneID,
            expectedDatabase: activeScope.databaseScope
        )
    }

    /// Validates that this identity matches the expected active parameters. Throws if there's a mismatch.
    func validateScope(
        expectedFamily: String?,
        expectedZone: CKRecordZone.ID?,
        expectedDatabase: CKDatabase.Scope?
    ) throws {
        if let expectedDatabase, databaseScope != expectedDatabase {
            throw ScopeValidationError.databaseMismatch(
                expected: expectedDatabase,
                actual: databaseScope
            )
        }
        if let expectedZone, zoneID != expectedZone {
            throw ScopeValidationError.zoneMismatch(
                expected: expectedZone,
                actual: zoneID
            )
        }
        if let expectedFamily {
            guard let actualFamily = familyRecordName, expectedFamily == actualFamily else {
                throw ScopeValidationError.familyMismatch(
                    expected: expectedFamily,
                    actual: familyRecordName ?? "nil"
                )
            }
        }
    }

    /// Non-throwing boolean check for filtering incoming sync changes.
    func matchesActiveScope(
        expectedFamily: String?,
        expectedZone: CKRecordZone.ID?,
        expectedDatabase: CKDatabase.Scope?
    ) -> Bool {
        if let expectedDatabase, databaseScope != expectedDatabase {
            return false
        }
        if let expectedZone, zoneID != expectedZone {
            return false
        }
        if let expectedFamily {
            guard let actualFamily = familyRecordName, expectedFamily == actualFamily else {
                return false
            }
        }
        return true
    }
}

extension ScopedRecordIdentity: CustomStringConvertible {
    var description: String {
        "ScopedRecordIdentity(db: \(databaseScopeString), zone: \(zoneID.zoneName), record: \(recordName), family: \(familyRecordName ?? "nil"))"
    }
}

enum ScopeValidationError: Error, LocalizedError {
    case databaseMismatch(expected: CKDatabase.Scope, actual: CKDatabase.Scope)
    case zoneMismatch(expected: CKRecordZone.ID, actual: CKRecordZone.ID)
    case familyMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case let .databaseMismatch(expected, actual):
            "Record database scope mismatch: expected \(expected), got \(actual)"
        case let .zoneMismatch(expected, actual):
            "Record zone mismatch: expected \(expected), got \(actual)"
        case let .familyMismatch(expected, actual):
            "Record family mismatch: expected \(expected), got \(actual)"
        }
    }
}
