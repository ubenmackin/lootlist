//
//  CKSyncEngineCoordinatorTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/13/26.
//

import CloudKit
import Foundation
@testable import LootList
import XCTest

@MainActor
final class CKSyncEngineCoordinatorTests: XCTestCase {
    var appState: AppState!
    var cloudKit: MockCloudKitService!
    var cacheService: CacheService!
    var delegateHandler: CKSyncEngineDelegateHandler!
    var coordinator: CKSyncEngineCoordinator!
    var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        let suite = "test-suite-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        appState = AppState(defaults: defaults)
        cloudKit = MockCloudKitService()

        cacheService = try CacheService(inMemory: true)
        cacheService.invalidateAllFreshness()
        appState.cacheService = cacheService

        appState.family = Family(
            name: "Family",
            createdBy: CKRecord.ID(recordName: "user"),
            id: CKRecord.ID(recordName: "active-family")
        )

        let conflictResolver = CKSyncConflictResolver(
            cacheService: cacheService,
            appState: appState
        )

        let bgActor = BackgroundCacheActor(container: cacheService.container!)

        delegateHandler = CKSyncEngineDelegateHandler(
            backgroundCache: bgActor,
            conflictResolver: conflictResolver,
            cacheService: cacheService,
            appState: appState
        )

        coordinator = CKSyncEngineCoordinator(
            cloudKitService: cloudKit,
            delegateHandler: delegateHandler,
            appState: appState,
            defaults: defaults
        )
    }

    override func tearDown() async throws {
        cacheService?.invalidateAllFreshness()
        try await super.tearDown()
    }

    func testAppStateInitialization() {
        XCTAssertNotNil(coordinator.delegateHandler)
        XCTAssertEqual(coordinator.isSyncing, false)
        XCTAssertNil(coordinator.syncError)
    }

    func testNilEngineFetchChangesDoesNotStampFreshness() async {
        // In test mode without initialized CKSyncEngine instances, fetchChanges
        // must NOT falsely mark the cache as fresh.
        XCTAssertNil(coordinator.privateSyncEngine)
        XCTAssertNil(coordinator.sharedSyncEngine)

        await coordinator.fetchChanges()

        let types = CachedRecordType.allCases
        for type in types {
            let isFresh = cacheService.isCacheFresh(familyRecordName: "active-family", type: type)
            XCTAssertFalse(isFresh, "Cache should NOT be fresh for \(type) when engines are nil")
        }
    }

    func testSendPendingChangesDoesNotStampFreshness() async throws {
        try cacheService.clearAll()

        await coordinator.sendPendingChanges()

        let types = CachedRecordType.allCases
        for type in types {
            let isFresh = cacheService.isCacheFresh(familyRecordName: "active-family", type: type)
            XCTAssertFalse(isFresh, "Cache should NOT be fresh for \(type) after a send pass")
        }
    }

    func testStatePersistenceScopedKeys() {
        let accountID = "active-family"
        let privateKey = "ck_sync_engine_state.\(accountID).private"
        let sharedKey = "ck_sync_engine_state.\(accountID).shared"

        XCTAssertNil(defaults.data(forKey: privateKey))
        XCTAssertNil(defaults.data(forKey: sharedKey))
        XCTAssertNil(coordinator.loadState(for: .private))
        XCTAssertNil(coordinator.loadState(for: .shared))
    }

    func testResetStateClearsScopedAndLegacyKeys() {
        let accountID = "active-family"
        let privateKey = "ck_sync_engine_state.\(accountID).private"
        let sharedKey = "ck_sync_engine_state.\(accountID).shared"

        defaults.set(Data([0x01, 0x02]), forKey: privateKey)
        defaults.set(Data([0x03, 0x04]), forKey: sharedKey)
        defaults.set(Data([0x05]), forKey: "ck_sync_engine_state_private")
        defaults.set(Data([0x06]), forKey: "ck_sync_engine_state_shared")

        coordinator.resetState()

        XCTAssertNil(defaults.data(forKey: privateKey))
        XCTAssertNil(defaults.data(forKey: sharedKey))
        XCTAssertNil(defaults.data(forKey: "ck_sync_engine_state_private"))
        XCTAssertNil(defaults.data(forKey: "ck_sync_engine_state_shared"))
    }

    func testRealFetchPassEndToEndHydratesCacheAndStampsFreshness() async {
        for type in CachedRecordType.allCases {
            XCTAssertFalse(cacheService.isCacheFresh(familyRecordName: "active-family", type: type))
        }

        let family = Family(
            name: "Active Family",
            createdBy: CKRecord.ID(recordName: "user1"),
            id: CKRecord.ID(recordName: "active-family")
        )
        let familyRecord = family.toRecord()

        let profile = Profile(
            displayName: "Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "icloud-user-1"),
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: "hero-profile")
        )
        let profileRecord = profile.toRecord()

        let template = QuestTemplate(
            name: "Clean Room",
            description: "Keep it clean",
            defaultGold: 10.0,
            xpReward: 25,
            scheduleType: .weeklyFlexible,
            createdBy: CKRecord.Reference(recordID: profile.id, action: .none),
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: "tpl-1")
        )
        let templateRecord = template.toRecord()

        let quest = Quest(
            template: CKRecord.Reference(recordID: template.id, action: .none),
            assignee: CKRecord.Reference(recordID: profile.id, action: .none),
            goldReward: 10.0,
            xpReward: 25,
            scheduleType: .weeklyFlexible,
            weekOf: Date(),
            createdBy: CKRecord.Reference(recordID: profile.id, action: .none),
            family: CKRecord.Reference(recordID: family.id, action: .none),
            name: "Clean Room",
            id: CKRecord.ID(recordName: "quest-1")
        )
        let questRecord = quest.toRecord()

        // Process incoming records through the delegate pipeline
        await delegateHandler.handleIncomingRecordsDirectly([familyRecord, profileRecord, templateRecord, questRecord])

        // Complete the fetch pass settlement for active scope
        coordinator.simulateFetchPassSettlement(activeScopes: [.private], completedScopes: [.private])

        // Verify cache rows exist in SwiftData
        XCTAssertNotNil(cacheService.fetchFamily(recordName: "active-family"))
        XCTAssertNotNil(cacheService.fetchProfile(recordName: "hero-profile", family: "active-family"))
        XCTAssertNotNil(cacheService.fetchQuest(recordName: "quest-1", family: "active-family"))
        XCTAssertNotNil(cacheService.fetchQuestTemplate(recordName: "tpl-1", family: "active-family"))

        // Verify that freshness is now stamped for active family
        for type in CachedRecordType.allCases {
            XCTAssertTrue(cacheService.isCacheFresh(familyRecordName: "active-family", type: type), "Cache should be fresh for \(type) after successful fetch pass")
        }
    }

    func testRealFetchPassWithParseFailureDoesNotStampFreshness() async {
        let badRecord = CKRecord(recordType: "CorruptedRecordType", recordID: CKRecord.ID(recordName: "corrupt-1"))
        await delegateHandler.handleIncomingRecordsDirectly([badRecord])

        coordinator.simulateFetchPassSettlement(activeScopes: [.private], completedScopes: [.private])

        for type in CachedRecordType.allCases {
            XCTAssertFalse(cacheService.isCacheFresh(familyRecordName: "active-family", type: type), "Parse failures must block freshness stamping for \(type)")
        }
    }

    func testRealFetchPassWithIncompleteScopesDoesNotStampFreshness() {
        // Active scopes has both .private and .shared, but only .private finished
        coordinator.simulateFetchPassSettlement(activeScopes: [.private, .shared], completedScopes: [.private])

        for type in CachedRecordType.allCases {
            XCTAssertFalse(cacheService.isCacheFresh(familyRecordName: "active-family", type: type), "Incomplete database engine passes must block freshness stamping for \(type)")
        }
    }

    func testRealFetchPassWithCacheWriteFailureDoesNotStampFreshness() {
        coordinator.noteCacheWriteFailure()
        coordinator.simulateFetchPassSettlement(activeScopes: [.private], completedScopes: [.private])

        for type in CachedRecordType.allCases {
            XCTAssertFalse(cacheService.isCacheFresh(familyRecordName: "active-family", type: type), "Cache write failures must block freshness stamping for \(type)")
        }
    }

    func testStatePersistenceWithoutAccountIDDoesNotWriteDefaultKey() {
        // When appState has no profile and no family, saving state must be safely skipped
        appState.family = nil
        appState.currentProfile = nil

        let defaultPrivateKey = "ck_sync_engine_state.default.private"
        let defaultSharedKey = "ck_sync_engine_state.default.shared"

        XCTAssertNil(defaults.data(forKey: defaultPrivateKey))
        XCTAssertNil(defaults.data(forKey: defaultSharedKey))
        XCTAssertNil(coordinator.loadState(for: .private))
        XCTAssertNil(coordinator.loadState(for: .shared))
    }

    func testResetStateWithExplicitAccountID() {
        let oldAccountID = "previous-user"
        let privateKey = "ck_sync_engine_state.\(oldAccountID).private"
        let sharedKey = "ck_sync_engine_state.\(oldAccountID).shared"

        defaults.set(Data([0x10, 0x20]), forKey: privateKey)
        defaults.set(Data([0x30, 0x40]), forKey: sharedKey)

        coordinator.resetState(forAccountID: oldAccountID)

        XCTAssertNil(defaults.data(forKey: privateKey))
        XCTAssertNil(defaults.data(forKey: sharedKey))
    }

    func testEnqueueSaveAndEnqueueDelete() {
        let recordID = CKRecord.ID(recordName: "test-record")

        XCTAssertNoThrow(coordinator.enqueueSave(recordID: recordID, isOwner: true))
        XCTAssertNoThrow(coordinator.enqueueDelete(recordID: recordID, isOwner: true))
    }

    func testStateKeyAccountIsolation() {
        let accountA = "family-alpha"
        let accountB = "family-beta"

        let privateKeyA = "ck_sync_engine_state.\(accountA).private"
        let sharedKeyA = "ck_sync_engine_state.\(accountA).shared"
        let privateKeyB = "ck_sync_engine_state.\(accountB).private"
        let sharedKeyB = "ck_sync_engine_state.\(accountB).shared"

        defaults.set(Data([0xAA, 0x01]), forKey: privateKeyA)
        defaults.set(Data([0xAA, 0x02]), forKey: sharedKeyA)
        defaults.set(Data([0xBB, 0x01]), forKey: privateKeyB)
        defaults.set(Data([0xBB, 0x02]), forKey: sharedKeyB)

        // Reset state for account A only
        coordinator.resetState(forAccountID: accountA)

        // Account A keys must be wiped
        XCTAssertNil(defaults.data(forKey: privateKeyA))
        XCTAssertNil(defaults.data(forKey: sharedKeyA))

        // Account B keys must remain intact
        XCTAssertEqual(defaults.data(forKey: privateKeyB), Data([0xBB, 0x01]))
        XCTAssertEqual(defaults.data(forKey: sharedKeyB), Data([0xBB, 0x02]))
    }

    private final class NotificationBox: @unchecked Sendable {
        var outcome: SyncOutcome?
    }

    func testSyncDidCompleteNotificationOutcome() async {
        let box = NotificationBox()
        let expectation = expectation(description: "syncDidComplete notification received")

        let observer = NotificationCenter.default.addObserver(
            forName: .syncDidComplete,
            object: coordinator,
            queue: .main
        ) { notification in
            box.outcome = notification.userInfo?[SyncOutcome.userInfoKey] as? SyncOutcome
            expectation.fulfill()
        }

        coordinator.noteChangesProcessed()
        coordinator.simulateFetchPassSettlement(activeScopes: [.private], completedScopes: [.private])

        await fulfillment(of: [expectation], timeout: 2.0)
        NotificationCenter.default.removeObserver(observer)

        XCTAssertEqual(box.outcome, .changed)
    }
}
