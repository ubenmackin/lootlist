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
///
/// Decomposed into Sendable primitive types (`String` and `CKDatabase.Scope`)
/// for 100% compiler-verified `Sendable` conformance.
/// Vends `CKRecordZone.ID` and `CKRecord.ID` on demand via computed properties.
struct ScopedRecordIdentity: Hashable, Sendable {
    let databaseScope: CKDatabase.Scope
    let zoneName: String
    let zoneOwnerName: String
    let recordName: String
    let familyRecordName: String?

    var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: zoneOwnerName)
    }

    var recordID: CKRecord.ID {
        CKRecord.ID(recordName: recordName, zoneID: zoneID)
    }

    init(
        databaseScope: CKDatabase.Scope,
        zoneID: CKRecordZone.ID,
        recordID: CKRecord.ID,
        familyRecordName: String?
    ) {
        self.databaseScope = databaseScope
        self.zoneName = zoneID.zoneName
        self.zoneOwnerName = zoneID.ownerName
        self.recordName = recordID.recordName
        self.familyRecordName = familyRecordName
    }

    init(
        databaseScope: CKDatabase.Scope,
        zoneName: String,
        zoneOwnerName: String,
        recordName: String,
        familyRecordName: String?
    ) {
        self.databaseScope = databaseScope
        self.zoneName = zoneName
        self.zoneOwnerName = zoneOwnerName
        self.recordName = recordName
        self.familyRecordName = familyRecordName
    }

    init(from record: CKRecord, databaseScope: CKDatabase.Scope, familyRecordName: String?) {
        self.databaseScope = databaseScope
        self.zoneName = record.recordID.zoneID.zoneName
        self.zoneOwnerName = record.recordID.zoneID.ownerName
        self.recordName = record.recordID.recordName
        self.familyRecordName = familyRecordName
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
