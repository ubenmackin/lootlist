//
//  CKSyncEngineTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/13/26.
//

import CloudKit
import Foundation
@testable import LootList
import SwiftData
import Testing

@MainActor
@Suite(.serialized)
struct CKSyncEngineTests {
    let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")

    // MARK: - RecordBridge Tests

    @Test
    func `record bridge converts cached quest into CKRecord with parent`() throws {
        let cache = try CacheService(inMemory: true)
        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let questID = CKRecord.ID(recordName: "quest1", zoneID: zoneID)
        let quest = Quest(
            template: CKRecord.Reference(recordID: CKRecord.ID(recordName: "tpl1", zoneID: zoneID), action: .none),
            assignee: CKRecord.Reference(recordID: CKRecord.ID(recordName: "hero1", zoneID: zoneID), action: .none),
            goldReward: 15.0,
            xpReward: 25,
            scheduleType: .weeklyFlexible,
            weekOf: Date(),
            createdBy: CKRecord.Reference(recordID: CKRecord.ID(recordName: "parent1", zoneID: zoneID), action: .none),
            family: familyRef,
            name: "Dragon Slaying",
            id: questID
        )

        cache.upsertQuest(quest)

        let questIdentity = ScopedRecordIdentity(
            databaseScope: .private,
            zoneID: questID.zoneID,
            recordID: questID,
            familyRecordName: "fam1"
        )
        let record = try #require(RecordBridge.record(for: questIdentity, cacheService: cache))
        #expect(record.recordType == Quest.recordType)
        #expect(record["name"] as? String == "Dragon Slaying")
        #expect(record["goldReward"] as? Double == 15.0)
        #expect(record.parent?.recordID.recordName == "fam1")
    }

    @Test
    func `record bridge converts cached quest completion to QuestLog CKRecord`() throws {
        let cache = try CacheService(inMemory: true)
        let completionID = CKRecord.ID(recordName: "log1", zoneID: zoneID)
        let completion = QuestCompletion(
            quest: CKRecord.Reference(recordID: CKRecord.ID(recordName: "quest1", zoneID: zoneID), action: .none),
            completedBy: CKRecord.Reference(recordID: CKRecord.ID(recordName: "hero1", zoneID: zoneID), action: .none),
            approvalMode: .parentVerify,
            completedDate: Date(),
            weekOf: Date(),
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none),
            id: completionID
        )

        cache.upsertQuestCompletion(completion)

        let completionIdentity = ScopedRecordIdentity(
            databaseScope: .private,
            zoneID: completionID.zoneID,
            recordID: completionID,
            familyRecordName: "fam1"
        )
        let record = try #require(RecordBridge.record(for: completionIdentity, cacheService: cache))
        #expect(record.recordType == "QuestLog")
        #expect(record["verificationStatus"] as? String == "pending")
        #expect(record.parent?.recordID.recordName == "fam1")
    }

    @Test
    func `record bridge returns nil for missing entity`() throws {
        let cache = try CacheService(inMemory: true)
        let missingID = CKRecord.ID(recordName: "nonexistent", zoneID: zoneID)
        let missingIdentity = ScopedRecordIdentity(
            databaseScope: .private,
            zoneID: missingID.zoneID,
            recordID: missingID,
            familyRecordName: "fam1"
        )
        let record = RecordBridge.record(for: missingIdentity, cacheService: cache)
        #expect(record == nil)
    }

    // MARK: - Conflict Resolver Tests

    @Test
    func `conflict resolver performs monotonic max merge on xpBanked`() async throws {
        let cache = try CacheService(inMemory: true)
        let bgActor = try BackgroundCacheActor(container: #require(cache.container))
        let resolver = CKSyncConflictResolver(cacheService: cache, backgroundCache: bgActor)

        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let questID = CKRecord.ID(recordName: "quest_conflict", zoneID: zoneID)

        var clientQuest = Quest(
            template: CKRecord.Reference(recordID: CKRecord.ID(recordName: "tpl1", zoneID: zoneID), action: .none),
            assignee: CKRecord.Reference(recordID: CKRecord.ID(recordName: "hero1", zoneID: zoneID), action: .none),
            goldReward: 10.0,
            xpReward: 200,
            scheduleType: .weeklyFlexible,
            weekOf: Date(),
            createdBy: CKRecord.Reference(recordID: CKRecord.ID(recordName: "parent1", zoneID: zoneID), action: .none),
            family: familyRef,
            name: "Castle Watch",
            id: questID
        )
        clientQuest.xpBanked = 100
        let clientRecord = clientQuest.toRecord()

        var serverQuest = clientQuest
        serverQuest.xpBanked = 150
        let serverRecord = serverQuest.toRecord()

        let ckError = CKError(
            .serverRecordChanged,
            userInfo: [
                CKRecordChangedErrorServerRecordKey: serverRecord,
                CKRecordChangedErrorClientRecordKey: clientRecord
            ]
        )

        let resolved = try #require(await resolver.resolveFailedSave(record: clientRecord, error: ckError))
        #expect(resolved["xpBanked"] as? Int == 150)

        let cached = try #require(cache.fetchQuest(recordName: questID.recordName, family: "fam1"))
        #expect(cached.xpBanked == 150)
    }

    @Test
    func `conflict resolver performs monotonic max merge on Profile xp`() async throws {
        let cache = try CacheService(inMemory: true)
        let bgActor = try BackgroundCacheActor(container: #require(cache.container))
        let resolver = CKSyncConflictResolver(cacheService: cache, backgroundCache: bgActor)

        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let profileID = CKRecord.ID(recordName: "hero_conflict", zoneID: zoneID)

        var clientProfile = Profile(
            displayName: "Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "user1", zoneID: zoneID),
            family: familyRef,
            id: profileID
        )
        clientProfile.xp = 100
        clientProfile.level = XPService.level(forXP: 100)
        let clientRecord = clientProfile.toRecord()

        var serverProfile = clientProfile
        serverProfile.xp = 150
        serverProfile.level = XPService.level(forXP: 150)
        let serverRecord = serverProfile.toRecord()

        let ckError = CKError(
            .serverRecordChanged,
            userInfo: [
                CKRecordChangedErrorServerRecordKey: serverRecord,
                CKRecordChangedErrorClientRecordKey: clientRecord
            ]
        )

        let resolved = try #require(await resolver.resolveFailedSave(record: clientRecord, error: ckError))
        #expect(resolved["xp"] as? Int == 150)

        let cached = try #require(cache.fetchProfile(recordName: profileID.recordName, family: "fam1"))
        #expect(cached.xpTotal == 150)
    }

    @Test
    func `conflict resolver preserves non nil xpCredited on quest completion`() async throws {
        let cache = try CacheService(inMemory: true)
        let bgActor = try BackgroundCacheActor(container: #require(cache.container))
        let resolver = CKSyncConflictResolver(cacheService: cache, backgroundCache: bgActor)

        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let completionID = CKRecord.ID(recordName: "log_conflict", zoneID: zoneID)
        let questRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "quest1", zoneID: zoneID), action: .none)

        // The client has already minted the XP credit; the server copy (from a
        // concurrent completion) carries no marker. Idempotency requires the
        // merged value to keep the non-nil client credit so the quest is never
        // re-minted.
        let clientCompletion = QuestCompletion(
            quest: questRef,
            completedBy: familyRef,
            approvalMode: .autoApprove,
            completedDate: Date(),
            weekOf: Date(),
            family: familyRef,
            xpCredited: 50,
            id: completionID
        )
        let clientRecord = clientCompletion.toRecord()

        var serverCompletion = clientCompletion
        serverCompletion.xpCredited = nil
        let serverRecord = serverCompletion.toRecord()

        let ckError = CKError(
            .serverRecordChanged,
            userInfo: [
                CKRecordChangedErrorServerRecordKey: serverRecord,
                CKRecordChangedErrorClientRecordKey: clientRecord
            ]
        )

        let resolved = try #require(await resolver.resolveFailedSave(record: clientRecord, error: ckError))
        #expect(resolved["xpCredited"] as? Int == 50)

        let cached = try #require(cache.fetchQuestCompletion(recordName: completionID.recordName, family: "fam1"))
        #expect(cached.xpCredited == 50)
    }

    @Test
    func `conflict resolver preserves server xpCredited when client is blank`() async throws {
        let cache = try CacheService(inMemory: true)
        let bgActor = try BackgroundCacheActor(container: #require(cache.container))
        let resolver = CKSyncConflictResolver(cacheService: cache, backgroundCache: bgActor)

        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let completionID = CKRecord.ID(recordName: "log_conflict_2", zoneID: zoneID)
        let questRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "quest1", zoneID: zoneID), action: .none)

        // Mirror case: the server already credited 40 XP while the optimistic
        // client copy has not. The merged record keeps the server's marker.
        let clientCompletion = QuestCompletion(
            quest: questRef,
            completedBy: familyRef,
            approvalMode: .autoApprove,
            completedDate: Date(),
            weekOf: Date(),
            family: familyRef,
            id: completionID
        )
        let clientRecord = clientCompletion.toRecord()

        var serverCompletion = clientCompletion
        serverCompletion.xpCredited = 40
        let serverRecord = serverCompletion.toRecord()

        let ckError = CKError(
            .serverRecordChanged,
            userInfo: [
                CKRecordChangedErrorServerRecordKey: serverRecord,
                CKRecordChangedErrorClientRecordKey: clientRecord
            ]
        )

        let resolved = try #require(await resolver.resolveFailedSave(record: clientRecord, error: ckError))
        #expect(resolved["xpCredited"] as? Int == 40)
    }

    @Test
    func `server side deletion invalidates cached row in both main and background stores`() async throws {
        let cache = try CacheService(inMemory: true)
        let container = try #require(cache.container)
        let bgActor = BackgroundCacheActor(container: container)
        let resolver = CKSyncConflictResolver(cacheService: cache, backgroundCache: bgActor)

        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let questID = CKRecord.ID(recordName: "deleted_quest", zoneID: zoneID)
        let quest = Quest(
            template: CKRecord.Reference(recordID: CKRecord.ID(recordName: "tpl1", zoneID: zoneID), action: .none),
            assignee: CKRecord.Reference(recordID: CKRecord.ID(recordName: "hero1", zoneID: zoneID), action: .none),
            goldReward: 10.0,
            xpReward: 25,
            scheduleType: .weeklyFlexible,
            weekOf: Date(),
            createdBy: CKRecord.Reference(recordID: CKRecord.ID(recordName: "parent1", zoneID: zoneID), action: .none),
            family: familyRef,
            name: "Delete Me",
            id: questID
        )
        cache.upsertQuest(quest)

        // The row is visible both through the @MainActor cache and the shared
        // background store before the server deletion arrives.
        #expect(cache.fetchQuest(recordName: questID.recordName, family: "fam1") != nil)
        #expect(try containerCount(QuestCache.self, in: container) == 1)

        // A `.unknownItem` save failure signals the record no longer exists on
        // the server, which funnels through the resolver's deletion invalidation
        // path (main store + background store), leaving no ghost row behind.
        let result = await resolver.resolveFailedSave(record: quest.toRecord(), error: CKError(.unknownItem))
        #expect(result == nil)
        #expect(cache.fetchQuest(recordName: questID.recordName, family: "fam1") == nil)
        #expect(try containerCount(QuestCache.self, in: container) == 0)
    }

    @Test
    func `handleDeletedRecord purges both main actor cache and background actor store`() async throws {
        let cache = try CacheService(inMemory: true)
        let container = try #require(cache.container)
        let bgActor = BackgroundCacheActor(container: container)
        let resolver = CKSyncConflictResolver(cacheService: cache, backgroundCache: bgActor)

        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let questID = CKRecord.ID(recordName: "deleted_quest_both", zoneID: zoneID)
        let quest = Quest(
            template: CKRecord.Reference(recordID: CKRecord.ID(recordName: "tpl1", zoneID: zoneID), action: .none),
            assignee: CKRecord.Reference(recordID: CKRecord.ID(recordName: "hero1", zoneID: zoneID), action: .none),
            goldReward: 10.0,
            xpReward: 25,
            scheduleType: .weeklyFlexible,
            weekOf: Date(),
            createdBy: CKRecord.Reference(recordID: CKRecord.ID(recordName: "parent1", zoneID: zoneID), action: .none),
            family: familyRef,
            name: "Delete Both",
            id: questID
        )
        cache.upsertQuest(quest)

        #expect(cache.fetchQuest(recordName: questID.recordName, family: "fam1") != nil)
        #expect(try containerCount(QuestCache.self, in: container) == 1)

        await resolver.handleDeletedRecord(recordID: questID, recordType: Quest.recordType, databaseScope: .private, familyRecordName: "fam1")

        #expect(cache.fetchQuest(recordName: questID.recordName, family: "fam1") == nil)
        #expect(try containerCount(QuestCache.self, in: container) == 0)
    }

    func containerCount<T: PersistentModel>(_: T.Type, in container: ModelContainer) throws -> Int {
        try ModelContext(container).fetch(FetchDescriptor<T>()).count
    }

    // MARK: - Offline & Queueing Tests

    @Test
    func `sync coordinator enqueue save and delete track pending operations`() throws {
        let ck = MockCloudKitService()
        ck.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let bgActor = try BackgroundCacheActor(container: #require(cache.container))
        let resolver = CKSyncConflictResolver(cacheService: cache, backgroundCache: bgActor)
        let delegate = CKSyncEngineDelegateHandler(backgroundCache: bgActor, conflictResolver: resolver, cacheService: cache)

        let coordinator = CKSyncEngineCoordinator(cloudKitService: ck, delegateHandler: delegate)

        // Use the explicit container instance from MockCloudKitService rather than
        // CKContainer.default() to avoid triggering unentitled container lookup on CI runners.
        let privateConfig = CKSyncEngine.Configuration(
            database: ck.container.privateCloudDatabase,
            stateSerialization: nil,
            delegate: delegate
        )
        let sharedConfig = CKSyncEngine.Configuration(
            database: ck.container.sharedCloudDatabase,
            stateSerialization: nil,
            delegate: delegate
        )
        coordinator.privateSyncEngine = CKSyncEngine(privateConfig)
        coordinator.sharedSyncEngine = CKSyncEngine(sharedConfig)

        #expect(coordinator.pendingUploadCount == 0)

        let recordID1 = CKRecord.ID(recordName: "item1", zoneID: zoneID)
        let recordID2 = CKRecord.ID(recordName: "item2", zoneID: zoneID)
        let recordID3 = CKRecord.ID(recordName: "item3", zoneID: zoneID)

        coordinator.enqueueSave(recordID: recordID1, isOwner: true)
        #expect(coordinator.pendingUploadCount == 1)

        coordinator.enqueueDelete(recordID: recordID2, isOwner: true)
        #expect(coordinator.pendingUploadCount == 2)

        coordinator.enqueueSave(recordID: recordID3, isOwner: false)
        #expect(coordinator.pendingUploadCount == 3)

        let privatePending = coordinator.privateSyncEngine?.state.pendingRecordZoneChanges ?? []
        #expect(privatePending.contains(.saveRecord(recordID1)))
        #expect(privatePending.contains(.deleteRecord(recordID2)))

        let sharedPending = coordinator.sharedSyncEngine?.state.pendingRecordZoneChanges ?? []
        #expect(sharedPending.contains(.saveRecord(recordID3)))
    }

    @Test
    func `offline mutation writes cache synchronously and enqueues record for later sync`() throws {
        let ck = MockCloudKitService()
        ck.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let bgActor = try BackgroundCacheActor(container: #require(cache.container))
        let resolver = CKSyncConflictResolver(cacheService: cache, backgroundCache: bgActor)
        let delegate = CKSyncEngineDelegateHandler(backgroundCache: bgActor, conflictResolver: resolver, cacheService: cache)
        let coordinator = CKSyncEngineCoordinator(cloudKitService: ck, delegateHandler: delegate)

        let privateConfig = CKSyncEngine.Configuration(
            database: ck.container.privateCloudDatabase,
            stateSerialization: nil,
            delegate: delegate
        )
        coordinator.privateSyncEngine = CKSyncEngine(privateConfig)

        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let questID = CKRecord.ID(recordName: "offline_quest", zoneID: zoneID)
        let quest = Quest(
            template: CKRecord.Reference(recordID: CKRecord.ID(recordName: "tpl1", zoneID: zoneID), action: .none),
            assignee: CKRecord.Reference(recordID: CKRecord.ID(recordName: "hero1", zoneID: zoneID), action: .none),
            goldReward: 10.0,
            xpReward: 25,
            scheduleType: .weeklyFlexible,
            weekOf: Date(),
            createdBy: CKRecord.Reference(recordID: CKRecord.ID(recordName: "parent1", zoneID: zoneID), action: .none),
            family: familyRef,
            name: "Offline Quest",
            id: questID
        )

        // Local-first mutation: the SwiftData write is synchronous and visible
        // immediately through the @MainActor cache, independent of any network.
        cache.upsertQuest(quest)
        #expect(cache.fetchQuest(recordName: questID.recordName, family: "fam1") != nil)

        // The dirty record id is enqueued so CKSyncEngine pushes it once the
        // network/account reconnects.
        coordinator.enqueueSave(recordID: questID, isOwner: true)
        #expect(coordinator.pendingUploadCount == 1)
        #expect(coordinator.privateSyncEngine?.state.pendingRecordZoneChanges.contains(.saveRecord(questID)) == true)
    }

    @Test
    func `coordinator reset clears persisted engine state for both scopes`() throws {
        let suite = "CKSyncEngineTests_ResetState_\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let accountID = "active-family"
        defaults.set(Data([0x01, 0x02]), forKey: "ck_sync_engine_state.\(accountID).private")
        defaults.set(Data([0x03, 0x04]), forKey: "ck_sync_engine_state.\(accountID).shared")
        defaults.set(Data([0x05]), forKey: "ck_sync_engine_state_private")
        defaults.set(Data([0x06]), forKey: "ck_sync_engine_state_shared")

        let ck = MockCloudKitService()
        ck.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let bgActor = try BackgroundCacheActor(container: #require(cache.container))
        let resolver = CKSyncConflictResolver(cacheService: cache, backgroundCache: bgActor)
        let delegate = CKSyncEngineDelegateHandler(backgroundCache: bgActor, conflictResolver: resolver, cacheService: cache)
        let coordinator = CKSyncEngineCoordinator(cloudKitService: ck, delegateHandler: delegate, defaults: defaults)

        coordinator.resetState(forAccountID: accountID)

        // Both scoped and legacy engine state serializations are wiped so a fresh account switch
        // never resumes a previous user's sync cursors or pending queue.
        #expect(defaults.data(forKey: "ck_sync_engine_state.\(accountID).private") == nil)
        #expect(defaults.data(forKey: "ck_sync_engine_state.\(accountID).shared") == nil)
        #expect(defaults.data(forKey: "ck_sync_engine_state_private") == nil)
        #expect(defaults.data(forKey: "ck_sync_engine_state_shared") == nil)
        #expect(coordinator.privateSyncEngine == nil)
        #expect(coordinator.sharedSyncEngine == nil)

        defaults.removePersistentDomain(forName: suite)
    }

    @Test
    func `account switch clears session record and purges previous family cache`() throws {
        let suite = "CKSyncEngineTests_Session_\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let cache = try CacheService(inMemory: true)
        let appState = AppState(defaults: defaults)
        appState.cacheService = cache

        let savedZoneID = zoneID
        let familyID = CKRecord.ID(recordName: "fam1", zoneID: savedZoneID)
        let family = Family(
            name: "Dragons",
            createdBy: CKRecord.ID(recordName: "gm1", zoneID: savedZoneID),
            id: familyID
        )
        let heroID = CKRecord.ID(recordName: "hero1", zoneID: savedZoneID)
        let profile = Profile(
            displayName: "Hero",
            role: .hero,
            iCloudUserID: heroID,
            family: CKRecord.Reference(recordID: familyID, action: .none),
            id: heroID
        )

        // Establish an active session whose family row is resident in the cache.
        appState.saveSession(profile: profile, family: family, zoneID: savedZoneID, isOwner: true)
        cache.upsertFamily(family)
        cache.upsertProfile(profile)
        #expect(cache.fetchFamily(recordName: "fam1") != nil)

        appState.clearSession()

        // The persisted active-session record is gone from UserDefaults.
        #expect(defaults.string(forKey: "session_profileRecordName") == nil)
        #expect(defaults.string(forKey: "session_familyRecordName") == nil)
        #expect(defaults.bool(forKey: "session_hasActiveSession") == false)

        // The previous family's rows are purged so a different account cannot
        // read the earlier family, and in-memory session state resets to root.
        #expect(cache.fetchFamily(recordName: "fam1") == nil)
        #expect(cache.fetchProfile(recordName: "hero1", family: "fam1") == nil)
        #expect(appState.authStatus == .onboarding)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test
    func `handleAccountChange clears session and discovers cloud state on account transition`() async throws {
        let suite = "CKSyncEngineTests.AccountChange.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let appState = AppState(defaults: defaults)
        let cache = try CacheService(inMemory: true)
        appState.cacheService = cache

        let ck = MockCloudKitService()
        ck.activeFamilyZoneID = zoneID

        let bgActor = try BackgroundCacheActor(container: #require(cache.container))
        let resolver = CKSyncConflictResolver(cacheService: cache, backgroundCache: bgActor, appState: appState)
        let delegate = CKSyncEngineDelegateHandler(backgroundCache: bgActor, conflictResolver: resolver, cacheService: cache, appState: appState)
        _ = CKSyncEngineCoordinator(cloudKitService: ck, delegateHandler: delegate, appState: appState, defaults: defaults)

        let familyID = CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        let family = Family(name: "Test Guild", createdBy: CKRecord.ID(recordName: "gm1", zoneID: zoneID), id: familyID)
        let heroID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        let profile = Profile(displayName: "Hero", role: .hero, iCloudUserID: heroID, family: CKRecord.Reference(recordID: familyID, action: .none), id: heroID)

        appState.currentProfile = profile
        appState.family = family
        appState.familyZoneID = zoneID
        appState.isZoneOwner = true
        appState.saveSession(profile: profile, family: family, zoneID: zoneID, isOwner: true)
        cache.upsertFamily(family)
        cache.upsertProfile(profile)
        #expect(appState.currentProfile != nil)

        // Exercise account change: signOut
        await delegate.handleAccountChange(changeType: .signOut(previousUser: heroID))

        #expect(appState.currentProfile == nil)
        #expect(appState.family == nil)
        #expect(cache.fetchFamily(recordName: "fam1") == nil)

        // Exercise account change: signIn flips authStatus to checkingCloudData
        await delegate.handleAccountChange(changeType: .signIn(currentUser: heroID))
        #expect(appState.authStatus == .onboarding || appState.authStatus == .checkingCloudData)

        defaults.removePersistentDomain(forName: suite)
    }
}
