//
//  ActiveFamilyScopeGuardTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/13/26.
//

import CloudKit
@testable import LootList
import XCTest

@MainActor
final class ActiveFamilyScopeGuardTests: XCTestCase {
    var appState: AppState!
    var cloudKit: MockCloudKitService!

    override func setUp() async throws {
        try await super.setUp()
        appState = AppState()
        cloudKit = MockCloudKitService()
    }

    func testRequireActiveFamily_Success() throws {
        let familyRecordID = CKRecord.ID(recordName: "active-family")
        appState.family = Family(name: "Test Family", createdBy: CKRecord.ID(recordName: "user1"), id: familyRecordID)

        XCTAssertNoThrow(try ActiveFamilyScopeGuard.requireActiveFamily(familyRecordName: "active-family", appState: appState))
    }

    func testRequireActiveFamily_ThrowsFamilyMismatch() throws {
        let familyRecordID = CKRecord.ID(recordName: "active-family")
        appState.family = Family(name: "Test Family", createdBy: CKRecord.ID(recordName: "user1"), id: familyRecordID)

        XCTAssertThrowsError(try ActiveFamilyScopeGuard.requireActiveFamily(familyRecordName: "other-family", appState: appState)) { error in
            guard case let ScopeViolation.familyMismatch(active, supplied) = error else {
                XCTFail("Expected familyMismatch, got \(error)")
                return
            }
            XCTAssertEqual(active, "active-family")
            XCTAssertEqual(supplied, "other-family")
        }
    }

    func testRequireActiveFamily_ThrowsNoActiveFamily() throws {
        appState.family = nil

        XCTAssertThrowsError(try ActiveFamilyScopeGuard.requireActiveFamily(familyRecordName: "active-family", appState: appState)) { error in
            guard case ScopeViolation.noActiveFamily = error else {
                XCTFail("Expected noActiveFamily, got \(error)")
                return
            }
        }
    }

    func testRequireActiveFamilyScope_Success() throws {
        let zoneID = CKRecordZone.default().zoneID
        let familyRecordID = CKRecord.ID(recordName: "active-family", zoneID: zoneID)
        appState.family = Family(name: "Test Family", createdBy: CKRecord.ID(recordName: "user1"), id: familyRecordID)
        appState.familyZoneID = zoneID
        appState.isZoneOwner = true
        cloudKit.activeFamilyZoneID = zoneID
        cloudKit.activeIsOwner = true

        XCTAssertNoThrow(try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            familyRecordName: "active-family",
            zoneID: zoneID,
            appState: appState,
            cloudKit: cloudKit
        ))
    }

    func testRequireActiveFamilyScope_ThrowsZoneMismatch() throws {
        let activeZone = CKRecordZone.default().zoneID
        let foreignZone = CKRecordZone.ID(zoneName: "foreign-zone", ownerName: "foreign-owner")
        let familyRecordID = CKRecord.ID(recordName: "active-family", zoneID: activeZone)
        appState.family = Family(name: "Test Family", createdBy: CKRecord.ID(recordName: "user1"), id: familyRecordID)
        appState.familyZoneID = activeZone
        appState.isZoneOwner = true
        cloudKit.activeFamilyZoneID = activeZone
        cloudKit.activeIsOwner = true

        XCTAssertThrowsError(try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            familyRecordName: "active-family",
            zoneID: foreignZone,
            appState: appState,
            cloudKit: cloudKit
        )) { error in
            guard case ScopeViolation.zoneMismatch = error else {
                XCTFail("Expected zoneMismatch, got \(error)")
                return
            }
        }
    }

    func testRequireActiveFamilyScope_ThrowsDatabaseMismatch() throws {
        let zoneID = CKRecordZone.default().zoneID
        let familyRecordID = CKRecord.ID(recordName: "active-family", zoneID: zoneID)
        appState.family = Family(name: "Test Family", createdBy: CKRecord.ID(recordName: "user1"), id: familyRecordID)
        appState.familyZoneID = zoneID
        appState.isZoneOwner = true
        cloudKit.activeFamilyZoneID = zoneID
        cloudKit.activeIsOwner = false // mismatch!

        XCTAssertThrowsError(try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            familyRecordName: "active-family",
            zoneID: zoneID,
            appState: appState,
            cloudKit: cloudKit
        )) { error in
            guard case ScopeViolation.databaseMismatch = error else {
                XCTFail("Expected databaseMismatch, got \(error)")
                return
            }
        }
    }

    func testRequireActiveFamilyScope_ThrowsNoActiveFamily() throws {
        let zoneID = CKRecordZone.default().zoneID
        appState.family = nil
        appState.familyZoneID = zoneID

        XCTAssertThrowsError(try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            familyRecordName: "active-family",
            zoneID: zoneID,
            appState: appState,
            cloudKit: cloudKit
        )) { error in
            guard case ScopeViolation.noActiveFamily = error else {
                XCTFail("Expected noActiveFamily, got \(error)")
                return
            }
        }
    }

    func testScopeViolationDescriptions() {
        let familyMismatch = ScopeViolation.familyMismatch(active: "famA", supplied: "famB")
        XCTAssertTrue(familyMismatch.errorDescription?.contains("famA") == true)

        let zoneA = CKRecordZone.ID(zoneName: "zoneA", ownerName: "ownerA")
        let zoneB = CKRecordZone.ID(zoneName: "zoneB", ownerName: "ownerB")
        let zoneMismatch = ScopeViolation.zoneMismatch(active: zoneA, supplied: zoneB)
        XCTAssertTrue(zoneMismatch.errorDescription?.contains("zoneA") == true)

        let dbMismatch = ScopeViolation.databaseMismatch(activeIsOwner: true, cloudKitIsOwner: false)
        XCTAssertNotNil(dbMismatch.errorDescription)

        let noFamily = ScopeViolation.noActiveFamily
        XCTAssertNotNil(noFamily.errorDescription)

        let noZone = ScopeViolation.noActiveZone
        XCTAssertNotNil(noZone.errorDescription)
    }
}
