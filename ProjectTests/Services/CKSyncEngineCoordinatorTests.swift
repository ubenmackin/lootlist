//
//  CKSyncEngineCoordinatorTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/13/26.
//

import CloudKit
import Foundation
@testable import LootList
import os
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
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
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

        let container = try XCTUnwrap(cacheService.container)
        let bgActor = BackgroundCacheActor(container: container)

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

    func testSyncDidCompleteNotificationOutcome() async {
        let outcomeLock = OSAllocatedUnfairLock<SyncOutcome?>(initialState: nil)
        let expectation = expectation(description: "syncDidComplete notification received")

        let observer = NotificationCenter.default.addObserver(
            forName: .syncDidComplete,
            object: coordinator,
            queue: .main
        ) { notification in
            let outcome = notification.userInfo?[SyncOutcome.userInfoKey] as? SyncOutcome
            outcomeLock.withLock { $0 = outcome }
            expectation.fulfill()
        }

        coordinator.noteChangesProcessed()
        coordinator.simulateFetchPassSettlement(activeScopes: [.private], completedScopes: [.private])

        await fulfillment(of: [expectation], timeout: 2.0)
        NotificationCenter.default.removeObserver(observer)

        XCTAssertEqual(outcomeLock.withLock { $0 }, .changed)
    }

    // MARK: - Stable stateKey Migration Suite

    func testStableStateKeyDerivedFromFamilyNotProfile() throws {
        let familyZoneID = CKRecordZone.ID(zoneName: "family-stable", ownerName: CKCurrentUserDefaultName)
        cloudKit.activeFamilyZoneID = familyZoneID
        appState.family = Family(name: "Stable", createdBy: CKRecord.ID(recordName: "user"), id: CKRecord.ID(recordName: "family-stable", zoneID: familyZoneID))
        appState.currentProfile = try Profile(
            displayName: "Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "user"),
            family: CKRecord.Reference(recordID: XCTUnwrap(appState.family?.id), action: .none),
            id: CKRecord.ID(recordName: "profile-orphan", zoneID: familyZoneID)
        )

        let privateKey = "ck_sync_engine_state.family-stable.private"
        let orphanPrivate = "ck_sync_engine_state.profile-orphan.private"
        let orphanShared = "ck_sync_engine_state.profile-orphan.shared"

        defaults.set(Data([0xAA]), forKey: orphanPrivate)
        defaults.set(Data([0xBB]), forKey: orphanShared)

        XCTAssertNil(coordinator.loadState(for: .private))
        XCTAssertNil(coordinator.loadState(for: .shared))

        XCTAssertEqual(defaults.data(forKey: orphanPrivate), Data([0xAA]))
        XCTAssertNil(defaults.data(forKey: privateKey))
    }

    func testStableStateKeyPrefersZoneNameOverFamilyRecordName() {
        let zoneID = CKRecordZone.ID(zoneName: "zone-family", ownerName: CKCurrentUserDefaultName)
        let familyZoneID = CKRecordZone.ID(zoneName: "other-family", ownerName: CKCurrentUserDefaultName)
        cloudKit.activeFamilyZoneID = zoneID
        appState.family = Family(name: "Other", createdBy: CKRecord.ID(recordName: "user"), id: CKRecord.ID(recordName: "other-family", zoneID: familyZoneID))

        let expectedPrivate = "ck_sync_engine_state.zone-family.private"
        let unexpectedPrivate = "ck_sync_engine_state.other-family.private"

        XCTAssertNil(defaults.data(forKey: expectedPrivate))
        XCTAssertNil(defaults.data(forKey: unexpectedPrivate))
        XCTAssertNil(coordinator.loadState(for: .private))
    }

    func testStableStateKeyUnchangedWhenProfileChanges() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "family-constant", ownerName: CKCurrentUserDefaultName)
        cloudKit.activeFamilyZoneID = zoneID
        appState.family = Family(name: "Constant", createdBy: CKRecord.ID(recordName: "user"), id: CKRecord.ID(recordName: "family-constant", zoneID: zoneID))
        appState.currentProfile = nil

        let validData = try await makeValidSerializationData(pendingName: "pending-1", zoneID: zoneID)
        let stablePrivate = "ck_sync_engine_state.family-constant.private"
        defaults.set(validData, forKey: stablePrivate)

        XCTAssertNotNil(coordinator.loadState(for: .private))
        XCTAssertEqual(defaults.data(forKey: stablePrivate), validData)

        let profile = try Profile(
            displayName: "NewHero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "user"),
            family: CKRecord.Reference(recordID: XCTUnwrap(appState.family?.id), action: .none),
            id: CKRecord.ID(recordName: "new-profile", zoneID: zoneID)
        )
        appState.currentProfile = profile

        XCTAssertNotNil(coordinator.loadState(for: .private))
        XCTAssertEqual(defaults.data(forKey: stablePrivate), validData)
        XCTAssertNil(defaults.data(forKey: "ck_sync_engine_state.new-profile.private"))
    }

    func testSaveStateScopesToStableFamilyKey() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "family-save", ownerName: CKCurrentUserDefaultName)
        cloudKit.activeFamilyZoneID = zoneID
        appState.family = Family(name: "Save", createdBy: CKRecord.ID(recordName: "user"), id: CKRecord.ID(recordName: "family-save", zoneID: zoneID))
        appState.currentProfile = try Profile(
            displayName: "Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "user"),
            family: CKRecord.Reference(recordID: XCTUnwrap(appState.family?.id), action: .none),
            id: CKRecord.ID(recordName: "profile-save", zoneID: zoneID)
        )

        let validData = try await makeValidSerializationData(pendingName: "save-pending", zoneID: zoneID)
        let serialization = try PropertyListDecoder().decode(CKSyncEngine.State.Serialization.self, from: validData)

        coordinator.saveState(serialization, for: .private)
        coordinator.saveState(serialization, for: .shared)

        XCTAssertNotNil(defaults.data(forKey: "ck_sync_engine_state.family-save.private"))
        XCTAssertNotNil(defaults.data(forKey: "ck_sync_engine_state.family-save.shared"))
        XCTAssertNil(defaults.data(forKey: "ck_sync_engine_state.profile-save.private"))
        XCTAssertNil(defaults.data(forKey: "ck_sync_engine_state.profile-save.shared"))
    }

    func testLoadStateMigratesLegacyProfileKeyToFamilyKey() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "family-migrate", ownerName: CKCurrentUserDefaultName)
        cloudKit.activeFamilyZoneID = zoneID
        appState.family = Family(name: "Migrate", createdBy: CKRecord.ID(recordName: "user"), id: CKRecord.ID(recordName: "family-migrate", zoneID: zoneID))
        let profile = try Profile(
            displayName: "Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "user"),
            family: CKRecord.Reference(recordID: XCTUnwrap(appState.family?.id), action: .none),
            id: CKRecord.ID(recordName: "profile-legacy", zoneID: zoneID)
        )
        appState.currentProfile = profile

        let validData = try await makeValidSerializationData(pendingName: "migrate-pending", zoneID: zoneID)
        let legacyKey = "ck_sync_engine_state.profile-legacy.private"
        let stableKey = "ck_sync_engine_state.family-migrate.private"
        defaults.set(validData, forKey: legacyKey)
        XCTAssertNil(defaults.data(forKey: stableKey))

        let loaded = coordinator.loadState(for: .private)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(defaults.data(forKey: stableKey), validData)
        XCTAssertEqual(defaults.data(forKey: legacyKey), validData)
    }

    func testLoadStateMigratesUnscopedLegacyToFamilyKey() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "family-unscoped", ownerName: CKCurrentUserDefaultName)
        cloudKit.activeFamilyZoneID = zoneID
        appState.family = Family(name: "Unscoped", createdBy: CKRecord.ID(recordName: "user"), id: CKRecord.ID(recordName: "family-unscoped", zoneID: zoneID))

        let validData = try await makeValidSerializationData(pendingName: "unscoped-pending", zoneID: zoneID)
        let legacyUnscoped = "ck_sync_engine_state_private"
        let stableKey = "ck_sync_engine_state.family-unscoped.private"
        defaults.set(validData, forKey: legacyUnscoped)
        XCTAssertNil(defaults.data(forKey: stableKey))

        let loaded = coordinator.loadState(for: .private)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(defaults.data(forKey: stableKey), validData)
    }

    func testLoadStatePriorityNewOverLegacyProfileOverUnscoped() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "family-priority", ownerName: CKCurrentUserDefaultName)
        cloudKit.activeFamilyZoneID = zoneID
        appState.family = Family(name: "Priority", createdBy: CKRecord.ID(recordName: "user"), id: CKRecord.ID(recordName: "family-priority", zoneID: zoneID))
        let profile = try Profile(
            displayName: "Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "user"),
            family: CKRecord.Reference(recordID: XCTUnwrap(appState.family?.id), action: .none),
            id: CKRecord.ID(recordName: "profile-priority", zoneID: zoneID)
        )
        appState.currentProfile = profile

        let stableData = try await makeValidSerializationData(pendingName: "stable-pending", zoneID: zoneID)
        let profileData = try await makeValidSerializationData(pendingName: "profile-pending", zoneID: zoneID)
        let unscopedData = try await makeValidSerializationData(pendingName: "unscoped-pending", zoneID: zoneID)

        let stableKey = "ck_sync_engine_state.family-priority.private"
        let profileKey = "ck_sync_engine_state.profile-priority.private"
        let unscopedKey = "ck_sync_engine_state_private"

        defaults.set(stableData, forKey: stableKey)
        defaults.set(profileData, forKey: profileKey)
        defaults.set(unscopedData, forKey: unscopedKey)

        let loaded = coordinator.loadState(for: .private)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(defaults.data(forKey: stableKey), stableData)

        defaults.removeObject(forKey: stableKey)
        let loadedProfile = coordinator.loadState(for: .private)
        XCTAssertNotNil(loadedProfile)
        XCTAssertEqual(defaults.data(forKey: stableKey), profileData)

        defaults.removeObject(forKey: profileKey)
        defaults.removeObject(forKey: stableKey)
        let loadedUnscoped = coordinator.loadState(for: .private)
        XCTAssertNotNil(loadedUnscoped)
        XCTAssertEqual(defaults.data(forKey: stableKey), unscopedData)
    }

    func testLoadStateChecksBothKeys() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "family-both", ownerName: CKCurrentUserDefaultName)
        cloudKit.activeFamilyZoneID = zoneID
        appState.family = Family(name: "Both", createdBy: CKRecord.ID(recordName: "user"), id: CKRecord.ID(recordName: "family-both", zoneID: zoneID))
        appState.currentProfile = try Profile(
            displayName: "Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "user"),
            family: CKRecord.Reference(recordID: XCTUnwrap(appState.family?.id), action: .none),
            id: CKRecord.ID(recordName: "profile-both", zoneID: zoneID)
        )

        let validData = try await makeValidSerializationData(pendingName: "both-pending", zoneID: zoneID)
        defaults.set(validData, forKey: "ck_sync_engine_state.profile-both.private")
        XCTAssertNil(defaults.data(forKey: "ck_sync_engine_state.family-both.private"))

        XCTAssertNotNil(coordinator.loadState(for: .private))
        XCTAssertNotNil(defaults.data(forKey: "ck_sync_engine_state.family-both.private"))

        defaults.removeObject(forKey: "ck_sync_engine_state.profile-both.private")
        defaults.removeObject(forKey: "ck_sync_engine_state.family-both.private")
        defaults.set(validData, forKey: "ck_sync_engine_state_private")
        XCTAssertNotNil(coordinator.loadState(for: .private))
        XCTAssertNotNil(defaults.data(forKey: "ck_sync_engine_state.family-both.private"))
    }

    func testResetStateClearsStableFamilyPlusOrphanedProfileKeys() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "family-reset", ownerName: CKCurrentUserDefaultName)
        cloudKit.activeFamilyZoneID = zoneID
        appState.family = Family(name: "Reset", createdBy: CKRecord.ID(recordName: "user"), id: CKRecord.ID(recordName: "family-reset", zoneID: zoneID))
        appState.currentProfile = try Profile(
            displayName: "Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "user"),
            family: CKRecord.Reference(recordID: XCTUnwrap(appState.family?.id), action: .none),
            id: CKRecord.ID(recordName: "profile-reset", zoneID: zoneID)
        )

        let validData = try await makeValidSerializationData(pendingName: "reset-pending", zoneID: zoneID)
        let stablePrivate = "ck_sync_engine_state.family-reset.private"
        let stableShared = "ck_sync_engine_state.family-reset.shared"
        let profilePrivate = "ck_sync_engine_state.profile-reset.private"
        let profileShared = "ck_sync_engine_state.profile-reset.shared"
        let legacyPrivate = "ck_sync_engine_state_private"
        let legacyShared = "ck_sync_engine_state_shared"
        let orphanPrivate = "ck_sync_engine_state.orphan-family.private"
        let orphanShared = "ck_sync_engine_state.orphan-family.shared"

        defaults.set(validData, forKey: stablePrivate)
        defaults.set(validData, forKey: stableShared)
        defaults.set(validData, forKey: profilePrivate)
        defaults.set(validData, forKey: profileShared)
        defaults.set(validData, forKey: legacyPrivate)
        defaults.set(validData, forKey: legacyShared)
        defaults.set(validData, forKey: orphanPrivate)
        defaults.set(validData, forKey: orphanShared)

        coordinator.resetState()

        XCTAssertNil(defaults.data(forKey: stablePrivate))
        XCTAssertNil(defaults.data(forKey: stableShared))
        XCTAssertNil(defaults.data(forKey: profilePrivate))
        XCTAssertNil(defaults.data(forKey: profileShared))
        XCTAssertNil(defaults.data(forKey: legacyPrivate))
        XCTAssertNil(defaults.data(forKey: legacyShared))
        XCTAssertNil(defaults.data(forKey: orphanPrivate))
        XCTAssertNil(defaults.data(forKey: orphanShared))
    }

    func testStampCacheFreshnessRequiresFamilyRecordName() {
        cacheService.invalidateAllFreshness()
        cloudKit.activeFamilyZoneID = CKRecordZone.ID(zoneName: "family-stamp", ownerName: CKCurrentUserDefaultName)
        appState.family = nil
        appState.currentProfile = nil

        coordinator.simulateFetchPassSettlement(activeScopes: [.private], completedScopes: [.private])

        for type in CachedRecordType.allCases {
            XCTAssertFalse(cacheService.isCacheFresh(familyRecordName: "family-stamp", type: type))
            XCTAssertFalse(cacheService.isCacheFresh(familyRecordName: "", type: type))
        }
    }

    func testStampCacheFreshnessNoZoneNameFallback() {
        cacheService.invalidateAllFreshness()
        let zoneID = CKRecordZone.ID(zoneName: "fallback-zone", ownerName: CKCurrentUserDefaultName)
        cloudKit.activeFamilyZoneID = zoneID
        appState.family = nil

        coordinator.simulateFetchPassSettlement(activeScopes: [.private], completedScopes: [.private])

        for type in CachedRecordType.allCases {
            XCTAssertFalse(cacheService.isCacheFresh(familyRecordName: "fallback-zone", type: type))
        }

        let family = Family(name: "Stamp", createdBy: CKRecord.ID(recordName: "user"), id: CKRecord.ID(recordName: "family-stamp-real", zoneID: zoneID))
        appState.family = family
        coordinator.simulateFetchPassSettlement(activeScopes: [.private], completedScopes: [.private])

        for type in CachedRecordType.allCases {
            XCTAssertTrue(cacheService.isCacheFresh(familyRecordName: "family-stamp-real", type: type))
        }
    }

    func testReOnboardingDoesNotOrphanPendingRecordZoneChanges() throws {
        let zoneID = CKRecordZone.ID(zoneName: "family-reonboard", ownerName: CKCurrentUserDefaultName)
        cloudKit.activeFamilyZoneID = zoneID
        appState.family = Family(name: "Reonboard", createdBy: CKRecord.ID(recordName: "user"), id: CKRecord.ID(recordName: "family-reonboard", zoneID: zoneID))
        appState.currentProfile = nil

        let container = MockCloudKitService.defaultContainer
        let delegate = try XCTUnwrap(delegateHandler)
        let privateConfig = CKSyncEngine.Configuration(database: container.privateCloudDatabase, stateSerialization: coordinator.loadState(for: .private), delegate: delegate)
        let sharedConfig = CKSyncEngine.Configuration(database: container.sharedCloudDatabase, stateSerialization: coordinator.loadState(for: .shared), delegate: delegate)
        coordinator.privateSyncEngine = CKSyncEngine(privateConfig)
        coordinator.sharedSyncEngine = CKSyncEngine(sharedConfig)

        let pendingID = CKRecord.ID(recordName: "pending-reonboard", zoneID: zoneID)
        coordinator.enqueueSave(recordID: pendingID, isOwner: true)
        XCTAssertEqual(coordinator.pendingUploadCount, 1)
        XCTAssertTrue(coordinator.privateSyncEngine?.state.pendingRecordZoneChanges.contains(.saveRecord(pendingID)) == true)

        let profile = try Profile(
            displayName: "Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "user"),
            family: CKRecord.Reference(recordID: XCTUnwrap(appState.family?.id), action: .none),
            id: CKRecord.ID(recordName: "profile-reonboard", zoneID: zoneID)
        )
        appState.currentProfile = profile

        XCTAssertEqual(coordinator.pendingUploadCount, 1, "Pending queue must survive profile nil -> real transition when stateKey is family-scoped")
        XCTAssertTrue(coordinator.privateSyncEngine?.state.pendingRecordZoneChanges.contains(.saveRecord(pendingID)) == true)
        XCTAssertNil(defaults.data(forKey: "ck_sync_engine_state.profile-reonboard.private"))

        let savedData = defaults.data(forKey: "ck_sync_engine_state.family-reonboard.private")
        if let savedData {
            let decoded = try PropertyListDecoder().decode(CKSyncEngine.State.Serialization.self, from: savedData)
            let freshDelegate = try CKSyncEngineDelegateHandler(
                backgroundCache: BackgroundCacheActor(container: XCTUnwrap(cacheService.container)),
                conflictResolver: CKSyncConflictResolver(cacheService: cacheService, appState: appState),
                cacheService: cacheService,
                appState: appState
            )
            let freshCoordinator = CKSyncEngineCoordinator(cloudKitService: cloudKit, delegateHandler: freshDelegate, appState: appState, defaults: defaults)
            let freshPrivate = CKSyncEngine(CKSyncEngine.Configuration(
                database: container.privateCloudDatabase,
                stateSerialization: freshCoordinator.loadState(for: .private),
                delegate: freshDelegate
            ))
            _ = decoded
            XCTAssertTrue(
                freshPrivate.state.pendingRecordZoneChanges.contains(.saveRecord(pendingID)),
                "Reloaded engine must retain pending change via stable family key"
            )
            _ = freshCoordinator
        }
    }

    // MARK: - Helpers

    private func makeValidSerializationData(pendingName: String, zoneID: CKRecordZone.ID) async throws -> Data {
        let delegate = CaptureDelegate()
        let container = MockCloudKitService.defaultContainer
        let config = CKSyncEngine.Configuration(database: container.privateCloudDatabase, stateSerialization: nil, delegate: delegate)
        let engine = CKSyncEngine(config)
        let recordID = CKRecord.ID(recordName: pendingName, zoneID: zoneID)
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        let serialization = await delegate.waitForSerialization(timeout: 1.0)
        if let serialization {
            return try PropertyListEncoder().encode(serialization)
        }
        let captured = try XCTUnwrap(delegate.capturedSerialization)
        return try PropertyListEncoder().encode(captured)
    }
}

@MainActor
private final class CaptureDelegate: NSObject, CKSyncEngineDelegate {
    var capturedSerialization: CKSyncEngine.State.Serialization?
    private var continuation: CheckedContinuation<CKSyncEngine.State.Serialization?, Never>?

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine _: CKSyncEngine) async {
        if case let .stateUpdate(stateEvent) = event {
            capturedSerialization = stateEvent.stateSerialization
            continuation?.resume(returning: stateEvent.stateSerialization)
            continuation = nil
        }
    }

    func nextRecordZoneChangeBatch(_: CKSyncEngine.SendChangesContext, syncEngine _: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        nil
    }

    func waitForSerialization(timeout: TimeInterval) async -> CKSyncEngine.State.Serialization? {
        if let capturedSerialization {
            return capturedSerialization
        }
        return await withCheckedContinuation { cont in
            continuation = cont
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let pending = self.continuation else { return }
                self.continuation = nil
                pending.resume(returning: nil)
            }
        }
    }
}
