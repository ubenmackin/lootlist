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
        XCTAssertNotNil(familyMismatch.errorDescription)

        let zoneA = CKRecordZone.ID(zoneName: "zoneA", ownerName: "ownerA")
        let zoneB = CKRecordZone.ID(zoneName: "zoneB", ownerName: "ownerB")
        let zoneMismatch = ScopeViolation.zoneMismatch(active: zoneA, supplied: zoneB)
        XCTAssertNotNil(zoneMismatch.errorDescription)

        let dbMismatch = ScopeViolation.databaseMismatch(activeIsOwner: true, cloudKitIsOwner: false)
        XCTAssertNotNil(dbMismatch.errorDescription)

        let noFamily = ScopeViolation.noActiveFamily
        XCTAssertNotNil(noFamily.errorDescription)

        let noZone = ScopeViolation.noActiveZone
        XCTAssertNotNil(noZone.errorDescription)
    }

    // MARK: - resolvedIsOwner Tests

    func testResolvedIsOwner_LocalOwnerWithPlaceholderZone() {
        let zoneID = CKRecordZone.ID(zoneName: "familyZone", ownerName: CKCurrentUserDefaultName)
        var family = Family(name: "Test Guild", createdBy: CKRecord.ID(recordName: "creatorUser", zoneID: zoneID), id: CKRecord.ID(recordName: "fam1", zoneID: zoneID))
        family.creatorUserRecordName = "5F1139BA-45A0-4FE9-8C48-4AE024752D62"
        let profile = Profile(
            displayName: "Dad",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: CKCurrentUserDefaultName, zoneID: zoneID),
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: "prof1", zoneID: zoneID)
        )
        appState.family = family
        appState.currentProfile = profile
        appState.familyZoneID = zoneID
        appState.isZoneOwner = true

        XCTAssertTrue(ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState))
    }

    func testResolvedIsOwner_ParticipantWithSharedZone_NonOwner() {
        let zoneID = CKRecordZone.ID(zoneName: "familyZone", ownerName: "5F1139BA-45A0-4FE9-8C48-4AE024752D62")
        var family = Family(
            name: "Test Guild",
            createdBy: CKRecord.ID(recordName: "5F1139BA-45A0-4FE9-8C48-4AE024752D62", zoneID: zoneID),
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
        family.creatorUserRecordName = "5F1139BA-45A0-4FE9-8C48-4AE024752D62"
        let childProfile = Profile(
            displayName: "HeroChild",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "B2EC4D2E-C841-4E8C-986A-2FB250D9E241", zoneID: zoneID),
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: "childProf1", zoneID: zoneID)
        )
        appState.family = family
        appState.currentProfile = childProfile
        appState.familyZoneID = zoneID
        appState.isZoneOwner = true // Erroneously true in stored defaults

        XCTAssertFalse(ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState))
    }
}
