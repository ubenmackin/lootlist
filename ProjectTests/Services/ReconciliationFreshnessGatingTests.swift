//
//  ReconciliationFreshnessGatingTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/28/26.
//

import CloudKit
import Foundation
@testable import LootList
import XCTest

@MainActor
final class ReconciliationFreshnessGatingTests: XCTestCase {
    var appState: AppState!
    var cacheService: CacheService!
    var delegateHandler: CKSyncEngineDelegateHandler!
    var coordinator: CKSyncEngineCoordinator!
    var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        let suite = "test-suite-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        appState = AppState(defaults: defaults)
        cacheService = try CacheService(inMemory: true)
        cacheService.invalidateAllFreshness()
        appState.cacheService = cacheService
        let resolver = CKSyncConflictResolver(cacheService: cacheService, appState: appState)
        let container = try XCTUnwrap(cacheService.container)
        let bgActor = BackgroundCacheActor(container: container)
        delegateHandler = CKSyncEngineDelegateHandler(
            backgroundCache: bgActor,
            conflictResolver: resolver,
            cacheService: cacheService,
            appState: appState
        )
        coordinator = CKSyncEngineCoordinator(
            cloudKitService: MockCloudKitService(),
            delegateHandler: delegateHandler,
            appState: appState,
            defaults: defaults
        )
    }

    override func tearDown() async throws {
        cacheService?.invalidateAllFreshness()
        try await super.tearDown()
    }

    func testIngestPartialFailureReportsOnlyFailedType() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "gating-zone", ownerName: CKCurrentUserDefaultName)
        appState.family = Family(name: "Gating", creatorUserRecordName: "user", id: CKRecord.ID(recordName: "active-family", zoneID: zoneID))
        appState.familyZoneID = zoneID
        let profile = try Profile(
            displayName: "Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "icloud-user-1", zoneID: zoneID),
            family: CKRecord.Reference(recordID: XCTUnwrap(appState.family?.id), action: .none),
            id: CKRecord.ID(recordName: "hero-profile", zoneID: zoneID)
        )
        let badQuest = CKRecord(recordType: Quest.recordType, recordID: CKRecord.ID(recordName: "bad-quest", zoneID: zoneID))
        let outcome = await delegateHandler.handleIncomingRecordsDirectly(
            [profile.toRecord(), badQuest],
            databaseScope: .private,
            zoneID: zoneID
        )
        let result = try XCTUnwrap(outcome)
        XCTAssertTrue(result.didCommit)
        XCTAssertTrue(result.failedTypes.contains(.quest))
        XCTAssertFalse(result.failedTypes.contains(.profile))
    }

    func testReconcilePartialFailureReportsOnlyFailedType() async throws {
        let container = try XCTUnwrap(cacheService.container)
        let actor = BackgroundCacheActor(container: container)
        let zoneID = CKRecordZone.ID(zoneName: "SharedGatingZone", ownerName: "parentUser")
        let familyID = CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        let profile = Profile(
            displayName: "Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "childUser", zoneID: zoneID),
            family: CKRecord.Reference(recordID: familyID, action: .none),
            id: CKRecord.ID(recordName: "childProf1", zoneID: zoneID)
        )
        let badQuest = CKRecord(recordType: Quest.recordType, recordID: CKRecord.ID(recordName: "bad-quest", zoneID: zoneID))
        let outcome = await actor.reconcileParticipantSet(
            records: [profile.toRecord(), badQuest],
            validRecordNamesByType: [.profile: ["childProf1"], .quest: ["bad-quest"]],
            familyRecordName: "fam1",
            databaseScope: .shared,
            zoneID: zoneID
        )
        let result = try XCTUnwrap(outcome)
        XCTAssertTrue(result.commitSucceeded)
        XCTAssertTrue(result.failedTypes.contains(.quest))
        XCTAssertFalse(result.failedTypes.contains(.profile))
    }

    func testOnlyCleanTypesStampFreshAfterPartialFailure() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "stamp-gating-zone", ownerName: CKCurrentUserDefaultName)
        appState.family = Family(name: "Stamp", creatorUserRecordName: "user", id: CKRecord.ID(recordName: "active-family", zoneID: zoneID))
        appState.familyZoneID = zoneID
        let profile = try Profile(
            displayName: "Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "icloud-user-1", zoneID: zoneID),
            family: CKRecord.Reference(recordID: XCTUnwrap(appState.family?.id), action: .none),
            id: CKRecord.ID(recordName: "hero-profile", zoneID: zoneID)
        )
        let badQuest = CKRecord(recordType: Quest.recordType, recordID: CKRecord.ID(recordName: "bad-quest", zoneID: zoneID))
        let outcome = await delegateHandler.handleIncomingRecordsDirectly(
            [profile.toRecord(), badQuest],
            databaseScope: .private,
            zoneID: zoneID
        )
        let fetched: Set<CachedRecordType> = [.profile, .quest]
        // WHY: clean types derive from fetch success minus ingest failures so partial failure keeps one side stale.
        let clean = fetched.subtracting(outcome?.failedTypes ?? [])
        coordinator.stampFreshness(for: clean, scopes: [.private])
        XCTAssertTrue(cacheService.isCacheFresh(familyRecordName: "active-family", type: .profile, scope: .private))
        XCTAssertFalse(cacheService.isCacheFresh(familyRecordName: "active-family", type: .quest, scope: .private))
    }
}
