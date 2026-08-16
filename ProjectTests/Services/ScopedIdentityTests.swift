//
//  ScopedIdentityTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/13/26.
//

import CloudKit
@testable import LootList
import XCTest

final class ScopedIdentityTests: XCTestCase {
    func testCompositeEquality() {
        let recordID = CKRecord.ID(recordName: "test-record", zoneID: CKRecordZone.default().zoneID)
        let otherZoneID = CKRecordZone.ID(zoneName: "other-zone", ownerName: CKCurrentUserDefaultName)
        let otherRecordID = CKRecord.ID(recordName: "test-record", zoneID: otherZoneID)

        let identity1 = ScopedRecordIdentity(
            databaseScope: .private,
            zoneID: recordID.zoneID,
            recordID: recordID,
            familyRecordName: "family-1"
        )
        let identity2 = ScopedRecordIdentity(
            databaseScope: .private,
            zoneID: recordID.zoneID,
            recordID: recordID,
            familyRecordName: "family-1"
        )
        let diffZone = ScopedRecordIdentity(
            databaseScope: .private,
            zoneID: otherZoneID,
            recordID: otherRecordID,
            familyRecordName: "family-1"
        )
        let diffDB = ScopedRecordIdentity(
            databaseScope: .shared,
            zoneID: recordID.zoneID,
            recordID: recordID,
            familyRecordName: "family-1"
        )
        let diffFamily = ScopedRecordIdentity(
            databaseScope: .private,
            zoneID: recordID.zoneID,
            recordID: recordID,
            familyRecordName: "family-2"
        )

        XCTAssertEqual(identity1, identity2)
        XCTAssertNotEqual(identity1, diffZone)
        XCTAssertNotEqual(identity1, diffDB)
        XCTAssertNotEqual(identity1, diffFamily)
    }

    func testValidateScope_Matches() throws {
        let recordID = CKRecord.ID(recordName: "test-record", zoneID: CKRecordZone.default().zoneID)
        let identity = ScopedRecordIdentity(
            databaseScope: .private,
            zoneID: recordID.zoneID,
            recordID: recordID,
            familyRecordName: "family-1"
        )
        let activeScope = ScopedRecordIdentity(
            databaseScope: .private,
            zoneID: recordID.zoneID,
            recordID: recordID,
            familyRecordName: "family-1"
        )

        XCTAssertNoThrow(try identity.validateScope(against: activeScope))
    }

    func testValidateScope_ThrowsMismatch() {
        let recordID = CKRecord.ID(recordName: "test-record", zoneID: CKRecordZone.default().zoneID)
        let otherZoneID = CKRecordZone.ID(zoneName: "other-zone", ownerName: CKCurrentUserDefaultName)

        let base = ScopedRecordIdentity(
            databaseScope: .private,
            zoneID: recordID.zoneID,
            recordID: recordID,
            familyRecordName: "family-1"
        )

        let activeDBMismatch = ScopedRecordIdentity(
            databaseScope: .shared,
            zoneID: recordID.zoneID,
            recordID: recordID,
            familyRecordName: "family-1"
        )
        XCTAssertThrowsError(try base.validateScope(against: activeDBMismatch)) { error in
            guard case ScopeValidationError.databaseMismatch = error else {
                XCTFail("Expected databaseMismatch, got \(error)")
                return
            }
        }

        let activeZoneMismatch = ScopedRecordIdentity(
            databaseScope: .private,
            zoneID: otherZoneID,
            recordID: recordID,
            familyRecordName: "family-1"
        )
        XCTAssertThrowsError(try base.validateScope(against: activeZoneMismatch)) { error in
            guard case ScopeValidationError.zoneMismatch = error else {
                XCTFail("Expected zoneMismatch, got \(error)")
                return
            }
        }

        let activeFamilyMismatch = ScopedRecordIdentity(
            databaseScope: .private,
            zoneID: recordID.zoneID,
            recordID: recordID,
            familyRecordName: "family-2"
        )
        XCTAssertThrowsError(try base.validateScope(against: activeFamilyMismatch)) { error in
            guard case ScopeValidationError.familyMismatch = error else {
                XCTFail("Expected familyMismatch, got \(error)")
                return
            }
        }
    }

    func testMatchesActiveScope_ReturnsTrueForMatchingScope() {
        let recordID = CKRecord.ID(recordName: "test-record", zoneID: CKRecordZone.default().zoneID)
        let identity = ScopedRecordIdentity(
            databaseScope: .private,
            zoneID: recordID.zoneID,
            recordID: recordID,
            familyRecordName: "family-1"
        )

        XCTAssertTrue(identity.matchesActiveScope(
            expectedFamily: "family-1",
            expectedZone: recordID.zoneID,
            expectedDatabase: .private
        ))

        XCTAssertFalse(identity.matchesActiveScope(
            expectedFamily: "foreign-family",
            expectedZone: recordID.zoneID,
            expectedDatabase: .private
        ))

        XCTAssertFalse(identity.matchesActiveScope(
            expectedFamily: "family-1",
            expectedZone: CKRecordZone.ID(zoneName: "foreign", ownerName: "foreign"),
            expectedDatabase: .private
        ))
    }

    func testSetAndDictionaryKeying() {
        let recordID = CKRecord.ID(recordName: "test-1", zoneID: CKRecordZone.default().zoneID)
        let id1 = ScopedRecordIdentity(databaseScope: .private, zoneID: recordID.zoneID, recordID: recordID, familyRecordName: "fam1")
        let id2 = ScopedRecordIdentity(databaseScope: .private, zoneID: recordID.zoneID, recordID: recordID, familyRecordName: "fam1")
        let id3 = ScopedRecordIdentity(databaseScope: .shared, zoneID: recordID.zoneID, recordID: recordID, familyRecordName: "fam1")

        var set: Set<ScopedRecordIdentity> = []
        set.insert(id1)
        set.insert(id2)
        set.insert(id3)

        XCTAssertEqual(set.count, 2)
    }

    func testScopedIdentityDescription() {
        let recordID = CKRecord.ID(recordName: "test-record", zoneID: CKRecordZone.default().zoneID)
        let identity = ScopedRecordIdentity(databaseScope: .private, zoneID: recordID.zoneID, recordID: recordID, familyRecordName: "fam-xyz")

        let desc = identity.description
        XCTAssertTrue(desc.contains("fam-xyz"))
        XCTAssertTrue(desc.contains("test-record"))
    }
}
