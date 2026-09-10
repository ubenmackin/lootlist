//
//  JetsamSurvivabilityTests.swift
//  LootList
//
//  Created by Ben Mackin on 9/10/26.
//

import CloudKit
import Foundation
@testable import LootList
import os
import Testing

@MainActor
struct JetsamSurvivabilityTests {
    private struct Stack {
        let zoneID: CKRecordZone.ID
        let mock: MockCloudKitService
        let cache: CacheService
        let appState: AppState
        let family: Family
        let parent: Profile
        let hero: Profile
        let handler: CKSyncEngineDelegateHandler
        let background: BackgroundCacheActor
    }

    private func makeStack() throws -> Stack {
        let zoneID = CKRecordZone.ID(zoneName: "JetsamZone", ownerName: "JetsamOwner")
        let mock = MockCloudKitService(zoneID: zoneID)
        mock.activeFamilyZoneID = zoneID
        mock.activeIsOwner = true
        let defaults = UserDefaults.ephemeral()
        let cache = try CacheService(inMemory: true, defaults: defaults)
        let appState = AppState.testState(defaults: defaults)
        appState.cacheService = cache
        let family = ExhaustiveCacheFixtures.sharedFamily(zoneID: zoneID)
        let parent = ExhaustiveCacheFixtures.sharedParent(zoneID: zoneID)
        let hero = ExhaustiveCacheFixtures.sharedHero(zoneID: zoneID)
        appState.family = family
        appState.familyZoneID = zoneID
        appState.currentProfile = parent
        appState.isZoneOwner = true
        appState.authStatus = .authenticated
        let container = try #require(cache.container)
        let background = BackgroundCacheActor(container: container)
        appState.backgroundCacheActor = background
        let resolver = CKSyncConflictResolver(cacheService: cache, appState: appState)
        let handler = CKSyncEngineDelegateHandler(
            backgroundCache: background,
            conflictResolver: resolver,
            cacheService: cache,
            appState: appState
        )
        return Stack(
            zoneID: zoneID,
            mock: mock,
            cache: cache,
            appState: appState,
            family: family,
            parent: parent,
            hero: hero,
            handler: handler,
            background: background
        )
    }

    private func sweepFixtureRecords(stack: Stack) -> [CKRecord] {
        sweepCoreRecords(stack: stack) + sweepRewardRecords(stack: stack)
    }

    private func sweepCoreRecords(stack: Stack) -> [CKRecord] {
        let zoneID = stack.zoneID
        let familyRef = CKRecord.Reference(recordID: stack.family.id, action: .none)
        let heroRef = CKRecord.Reference(recordID: stack.hero.id, action: .none)
        let parentRef = CKRecord.Reference(recordID: stack.parent.id, action: .none)
        let weekOf = Date(timeIntervalSince1970: 1_749_950_000)
        let id: (String) -> CKRecord.ID = { CKRecord.ID(recordName: $0, zoneID: zoneID) }

        let family = Family(
            name: "Jetsam Guild",
            creatorUserRecordName: MockCloudKitService.mockUserRecordName,
            id: stack.family.id
        )
        let profile = Profile(
            displayName: "Jetsam Extra",
            role: .hero,
            iCloudUserID: id("jetsam-icloud"),
            family: familyRef,
            id: id("jetsam-profile")
        )
        let template = QuestTemplate(
            name: "Jetsam Template",
            description: "Sweep cover",
            defaultGold: 500,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            createdBy: parentRef,
            family: familyRef,
            id: id("jetsam-template")
        )
        let quest = Quest(
            template: CKRecord.Reference(recordID: id("jetsam-template"), action: .none),
            assignee: heroRef,
            goldReward: 500,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            weekOf: weekOf,
            createdBy: parentRef,
            family: familyRef,
            name: "Jetsam Quest",
            id: id("jetsam-quest")
        )
        let completion = QuestCompletion(
            quest: CKRecord.Reference(recordID: id("jetsam-quest"), action: .none),
            completedBy: heroRef,
            approvalMode: .parentVerify,
            completedDate: weekOf,
            weekOf: weekOf,
            family: familyRef,
            id: id("jetsam-completion")
        )
        let ledger = LedgerEntry(
            profile: heroRef,
            amount: 1250,
            description: "Jetsam payout",
            source: LedgerSource.manual.rawValue,
            bucketKind: BucketKind.spend.rawValue,
            family: familyRef,
            id: id("jetsam-ledger")
        )
        let period = AllowancePeriod(
            weekOf: weekOf,
            profile: heroRef,
            questsTotal: 4,
            family: familyRef,
            id: id("jetsam-period")
        )
        let goal = Goal(
            profile: heroRef,
            family: familyRef,
            bucketKind: .shortTermSave,
            name: "Jetsam Bike",
            targetAmountPennies: 25000,
            id: id("jetsam-goal")
        )
        return [
            family.toRecord(),
            profile.toRecord(),
            template.toRecord(),
            quest.toRecord(),
            completion.toRecord(),
            ledger.toRecord(),
            period.toRecord(),
            goal.toRecord()
        ]
    }

    private func sweepRewardRecords(stack: Stack) -> [CKRecord] {
        let zoneID = stack.zoneID
        let familyRef = CKRecord.Reference(recordID: stack.family.id, action: .none)
        let heroRef = CKRecord.Reference(recordID: stack.hero.id, action: .none)
        let weekOf = Date(timeIntervalSince1970: 1_749_950_000)
        let id: (String) -> CKRecord.ID = { CKRecord.ID(recordName: $0, zoneID: zoneID) }

        let achievement = Achievement(
            id: id("jetsam-achievement"),
            name: "Jetsam First",
            description: "First sweep",
            iconSystemName: "star.fill",
            category: .quest,
            requirementType: .firstQuest,
            requirementValue: 1,
            family: familyRef
        )
        let profileAchievement = ProfileAchievement(
            achievement: CKRecord.Reference(recordID: id("jetsam-achievement"), action: .none),
            profile: heroRef,
            family: familyRef,
            id: id("jetsam-profile-achievement")
        )
        let preference = NotificationPreference(
            profile: heroRef,
            eventType: .questAssigned,
            enabled: true,
            family: familyRef,
            id: id("jetsam-preference")
        )
        let gem = GemLedger(
            profileRecordName: stack.hero.id.recordName,
            family: familyRef,
            amount: 25,
            source: "quest",
            sourceDetail: "sweep",
            id: id("jetsam-gem")
        )
        let reward = RewardEvent(
            profile: heroRef,
            questCompletion: CKRecord.Reference(recordID: id("jetsam-completion"), action: .none),
            xpAmount: 50,
            goldAmount: 500,
            timestamp: weekOf,
            family: familyRef,
            id: id("jetsam-reward")
        )
        return [
            achievement.toRecord(),
            profileAchievement.toRecord(),
            preference.toRecord(),
            gem.toRecord(),
            reward.toRecord()
        ]
    }

    private func expectedSweepNames() -> Set<String> {
        [
            "fam1",
            "jetsam-profile",
            "jetsam-template",
            "jetsam-quest",
            "jetsam-completion",
            "jetsam-ledger",
            "jetsam-period",
            "jetsam-goal",
            "jetsam-achievement",
            "jetsam-profile-achievement",
            "jetsam-preference",
            "jetsam-gem",
            "jetsam-reward"
        ]
    }

    @Test
    func `every ingested row left unsynced is discovered by launch scan`() async throws {
        ExhaustiveCacheFixtures.requireCanonicalCount()
        let stack = try makeStack()
        let records = sweepFixtureRecords(stack: stack)
        let outcome = await stack.handler.ingest(
            records: records,
            databaseScope: .private,
            zoneID: stack.zoneID,
            notifiesOnCompletion: false
        )
        #expect(outcome?.didCommit == true)
        let scanned = await (
            stack.background.fetchPendingRecordIDs(
                familyRecordName: stack.family.id.recordName,
                zoneID: stack.zoneID,
                trackedDroppedIdentities: []
            )
        ).recordIDsToEnqueue
        let names = Set(scanned.map(\.recordName))
        for expected in expectedSweepNames() {
            #expect(names.contains(expected), "Launch scan must surface unsynced row \(expected)")
        }
        let sorted = scanned.map(\.recordName).sorted()
        #expect(scanned.map(\.recordName) == sorted, "Scan order must stay deterministic across passes")
    }

    @Test
    func `synced rows stay out of launch scan`() async throws {
        let stack = try makeStack()
        let records = sweepFixtureRecords(stack: stack)
        await stack.handler.ingest(
            records: records,
            databaseScope: .private,
            zoneID: stack.zoneID,
            notifiesOnCompletion: false
        )
        let stamped = stack.cache.fetchLedgerEntry(recordName: "jetsam-ledger", family: stack.family.id.recordName)
        #expect(stamped != nil)
        stamped?.changeTag = "v1"
        _ = stack.cache.saveContext()
        let scanned = await (
            stack.background.fetchPendingRecordIDs(
                familyRecordName: stack.family.id.recordName,
                zoneID: stack.zoneID,
                trackedDroppedIdentities: []
            )
        ).recordIDsToEnqueue
        let names = Set(scanned.map(\.recordName))
        #expect(!names.contains("jetsam-ledger"), "Acked rows must not re-enqueue")
        #expect(names.contains("jetsam-quest"), "Unacked rows must still surface")
        #expect(names.contains("jetsam-goal"), "Unacked rows must still surface")
    }

    @Test
    func `launch re-enqueue delivers scanned identities to coordinator`() async throws {
        let stack = try makeStack()
        let records = sweepFixtureRecords(stack: stack)
        await stack.handler.ingest(
            records: records,
            databaseScope: .private,
            zoneID: stack.zoneID,
            notifiesOnCompletion: false
        )
        var scanned = await (
            stack.background.fetchPendingRecordIDs(
                familyRecordName: stack.family.id.recordName,
                zoneID: stack.zoneID,
                trackedDroppedIdentities: []
            )
        ).recordIDsToEnqueue
        scanned.sort { $0.recordName < $1.recordName }
        #expect(!scanned.isEmpty)
        let recorder = JetsamRecordingSync()
        ActiveFamilyScopeGuard.batchEnqueueWithCorrectedOwner(
            recorder,
            ids: scanned,
            appState: stack.appState,
            logger: Logger(category: "Test"),
            context: "JetsamSurvivabilityTests.reenqueue"
        )
        let saved = Set(recorder.saved)
        for expected in expectedSweepNames() {
            #expect(saved.contains(expected), "Re-enqueue must carry \(expected) to the engine")
        }
    }

    @Test
    func `quest delete captures tombstone before row removal`() async throws {
        let stack = try makeStack()
        let pastWeek = Date(timeIntervalSince1970: 1_700_000_000)
        let quest = Quest(
            template: CKRecord.Reference(recordID: CKRecord.ID(recordName: "jetsam-del-tpl", zoneID: stack.zoneID), action: .none),
            assignee: CKRecord.Reference(recordID: stack.hero.id, action: .none),
            goldReward: 500,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            weekOf: pastWeek,
            createdBy: CKRecord.Reference(recordID: stack.parent.id, action: .none),
            family: CKRecord.Reference(recordID: stack.family.id, action: .none),
            name: "Jetsam Delete Quest",
            id: CKRecord.ID(recordName: "jetsam-quest-delete", zoneID: stack.zoneID)
        )
        await stack.handler.ingest(
            records: [quest.toRecord()],
            databaseScope: .private,
            zoneID: stack.zoneID,
            notifiesOnCompletion: false
        )
        #expect(stack.cache.fetchQuest(recordName: "jetsam-quest-delete", family: stack.family.id.recordName) != nil)
        let recorder = JetsamRecordingSync()
        let service = QuestAssignmentService(
            cloudKit: stack.mock,
            cacheService: stack.cache,
            appState: stack.appState,
            syncCoordinator: recorder
        )
        try await service.unassignQuest(quest)
        #expect(stack.cache.fetchQuest(recordName: "jetsam-quest-delete", family: stack.family.id.recordName) == nil)
        #expect(recorder.deleted.contains("jetsam-quest-delete"))
        let scanned = await (
            stack.background.fetchPendingRecordIDs(
                familyRecordName: stack.family.id.recordName,
                zoneID: stack.zoneID,
                trackedDroppedIdentities: []
            )
        ).recordIDsToEnqueue
        #expect(!scanned.map(\.recordName).contains("jetsam-quest-delete"))
    }

    @Test
    func `goal delete captures tombstone before row removal`() async throws {
        let stack = try makeStack()
        let heroRef = CKRecord.Reference(recordID: stack.hero.id, action: .none)
        let familyRef = CKRecord.Reference(recordID: stack.family.id, action: .none)
        let goal = Goal(
            profile: heroRef,
            family: familyRef,
            bucketKind: .shortTermSave,
            name: "Jetsam Delete Goal",
            targetAmountPennies: 9000,
            id: CKRecord.ID(recordName: "jetsam-goal-delete", zoneID: stack.zoneID)
        )
        await stack.handler.ingest(
            records: [goal.toRecord()],
            databaseScope: .private,
            zoneID: stack.zoneID,
            notifiesOnCompletion: false
        )
        #expect(stack.cache.fetchGoal(recordName: "jetsam-goal-delete", family: stack.family.id.recordName) != nil)
        let recorder = JetsamRecordingSync()
        let service = GoalService(
            cloudKit: stack.mock,
            cacheService: stack.cache,
            appState: stack.appState,
            syncCoordinator: recorder
        )
        try await service.deleteGoal(goal, family: stack.family)
        #expect(stack.cache.fetchGoal(recordName: "jetsam-goal-delete", family: stack.family.id.recordName) == nil)
        #expect(recorder.deleted.contains("jetsam-goal-delete"))
    }

    @Test
    func `ledger delete captures tombstone before row removal`() async throws {
        let stack = try makeStack()
        let entry = LedgerEntry(
            profile: CKRecord.Reference(recordID: stack.hero.id, action: .none),
            amount: -500,
            description: "Jetsam snack",
            source: LedgerSource.manual.rawValue,
            bucketKind: BucketKind.spend.rawValue,
            family: CKRecord.Reference(recordID: stack.family.id, action: .none),
            id: CKRecord.ID(recordName: "jetsam-ledger-delete", zoneID: stack.zoneID)
        )
        await stack.handler.ingest(
            records: [entry.toRecord()],
            databaseScope: .private,
            zoneID: stack.zoneID,
            notifiesOnCompletion: false
        )
        #expect(stack.cache.fetchLedgerEntry(recordName: "jetsam-ledger-delete", family: stack.family.id.recordName) != nil)
        let recorder = JetsamRecordingSync()
        let service = LedgerService(
            cloudKit: stack.mock,
            cacheService: stack.cache,
            appState: stack.appState,
            syncCoordinator: recorder
        )
        try await service.delete(entry)
        #expect(stack.cache.fetchLedgerEntry(recordName: "jetsam-ledger-delete", family: stack.family.id.recordName) == nil)
        #expect(recorder.deleted.contains("jetsam-ledger-delete"))
    }

    @Test
    func `gem and bucket mutations are save-only with no delete surface`() async throws {
        let stack = try makeStack()
        let gems = GemService(
            cloudKitService: stack.mock,
            cacheService: stack.cache,
            appState: stack.appState
        )
        // WHY immutable ledger: gem credits append rows, so no delete call site exists to capture.
        let credited = try await gems.creditGems(
            amount: 10,
            to: stack.parent,
            source: "sweep",
            eventKey: "jetsam-gem-save-only"
        )
        #expect(credited)
        let gemRows = stack.cache.fetchGemLedgers(family: stack.family.id.recordName)
        #expect(!gemRows.isEmpty)

        let bucketRecorder = JetsamRecordingSync()
        let buckets = BucketService(
            cacheService: stack.cache,
            syncCoordinator: bucketRecorder,
            appState: stack.appState
        )
        stack.appState.currentProfile = stack.parent
        let seed = LedgerEntry(
            profile: CKRecord.Reference(recordID: stack.parent.id, action: .none),
            amount: 10000,
            description: "Jetsam seed",
            source: LedgerSource.manual.rawValue,
            bucketKind: BucketKind.spend.rawValue,
            family: CKRecord.Reference(recordID: stack.family.id, action: .none),
            id: CKRecord.ID(recordName: "jetsam-bucket-seed", zoneID: stack.zoneID)
        )
        await stack.cache.upsertLedgerEntry(seed)
        let moved = try await buckets.transfer(
            from: .spend,
            to: .shortTermSave,
            amount: 100,
            profile: stack.parent,
            family: stack.family,
            transferID: "jetsam-sweep-100-spend-shortTermSave"
        )
        #expect(moved.amount == 100)
        #expect(bucketRecorder.deleted.isEmpty, "Bucket transfers must never emit deletes")
        #expect(!bucketRecorder.saved.isEmpty, "Bucket transfers must enqueue the minted ledger save")
    }

    @Test
    func `unsynced scan never returns rows outside active family`() async throws {
        let stack = try makeStack()
        let records = sweepFixtureRecords(stack: stack)
        await stack.handler.ingest(
            records: records,
            databaseScope: .private,
            zoneID: stack.zoneID,
            notifiesOnCompletion: false
        )
        let foreign = LedgerEntry(
            profile: CKRecord.Reference(recordID: stack.hero.id, action: .none),
            amount: 999,
            description: "Foreign family",
            source: LedgerSource.manual.rawValue,
            bucketKind: BucketKind.spend.rawValue,
            family: CKRecord.Reference(
                recordID: CKRecord.ID(recordName: "fam-other", zoneID: stack.zoneID),
                action: .none
            ),
            id: CKRecord.ID(recordName: "jetsam-foreign", zoneID: stack.zoneID)
        )
        await stack.cache.upsertLedgerEntry(foreign)
        let scanned = await (
            stack.background.fetchPendingRecordIDs(
                familyRecordName: stack.family.id.recordName,
                zoneID: stack.zoneID,
                trackedDroppedIdentities: []
            )
        ).recordIDsToEnqueue
        let names = Set(scanned.map(\.recordName))
        #expect(!names.contains("jetsam-foreign"))
        #expect(names.contains("jetsam-ledger"))
        let foreignScan = await (
            stack.background.fetchPendingRecordIDs(
                familyRecordName: "fam-other",
                zoneID: stack.zoneID,
                trackedDroppedIdentities: []
            )
        ).recordIDsToEnqueue
        #expect(Set(foreignScan.map(\.recordName)).contains("jetsam-foreign"))
    }

    @Test
    func `ingest drops records outside active zone`() async throws {
        let stack = try makeStack()
        let foreignZone = CKRecordZone.ID(zoneName: "ForeignZone", ownerName: "ForeignOwner")
        let quest = Quest(
            template: CKRecord.Reference(
                recordID: CKRecord.ID(recordName: "jetsam-template", zoneID: foreignZone),
                action: .none
            ),
            assignee: CKRecord.Reference(
                recordID: CKRecord.ID(recordName: stack.hero.id.recordName, zoneID: foreignZone),
                action: .none
            ),
            goldReward: 100,
            xpReward: 10,
            scheduleType: .weeklyFlexible,
            weekOf: Date(),
            createdBy: CKRecord.Reference(
                recordID: CKRecord.ID(recordName: stack.parent.id.recordName, zoneID: foreignZone),
                action: .none
            ),
            family: CKRecord.Reference(
                recordID: CKRecord.ID(recordName: stack.family.id.recordName, zoneID: foreignZone),
                action: .none
            ),
            name: "Foreign Quest",
            id: CKRecord.ID(recordName: "jetsam-foreign-zone", zoneID: foreignZone)
        )
        let outcome = await stack.handler.ingest(
            records: [quest.toRecord()],
            databaseScope: .private,
            zoneID: foreignZone,
            notifiesOnCompletion: false
        )
        #expect(outcome == nil, "Fail-closed ingest must drop mismatched zones for later redelivery")
        #expect(stack.cache.fetchQuest(recordName: "jetsam-foreign-zone", family: stack.family.id.recordName) == nil)
    }

    @Test
    func `unsynced re-enqueue debounce collapses rapid triggers`() {
        let gate = AppLifecycleCoordinator.LifecycleSyncGate()
        let start = Date()
        #expect(gate.consumeUnsyncedTrigger(now: start) == true)
        #expect(gate.consumeUnsyncedTrigger(now: start.addingTimeInterval(5)) == false)
        #expect(
            gate.consumeUnsyncedTrigger(now: start.addingTimeInterval(
                AppLifecycleCoordinator.unsyncedEnqueueDebounceInterval + 1
            )) == true
        )
    }
}

@MainActor
private final class JetsamRecordingSync: SyncEnqueuing {
    var saved: [String] = []
    var deleted: [String] = []
    func enqueueSave(recordID: CKRecord.ID, isOwner _: Bool) {
        saved.append(recordID.recordName)
    }

    func enqueueDelete(recordID: CKRecord.ID, isOwner _: Bool) {
        deleted.append(recordID.recordName)
    }

    func batchEnqueueSave(recordIDs: [CKRecord.ID], isOwner _: Bool) {
        saved.append(contentsOf: recordIDs.map(\.recordName))
    }
}
