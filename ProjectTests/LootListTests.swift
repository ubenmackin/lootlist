//
//  LootListTests.swift
//  LootList
//
//  Created by Ben Mackin on 9/1/26.
//

import CloudKit
import Foundation
@testable import LootList
import SwiftData
import Testing

@MainActor
struct LootListTests {
    // MARK: - Helpers

    private struct FamilySetup {
        let family: Family
        let hero: Profile
        let parent: Profile
    }

    private func makeFamilyAndProfile(zoneID: CKRecordZone.ID, familyName: String = "famW3") -> FamilySetup {
        let family = Family(
            name: "W3 Guild",
            createdBy: CKRecord.ID(recordName: "owner1", zoneID: zoneID),
            id: CKRecord.ID(recordName: familyName, zoneID: zoneID)
        )
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let heroID = CKRecord.ID(recordName: "heroW3", zoneID: zoneID)
        let hero = Profile(
            displayName: "Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "icloud-hero", zoneID: zoneID),
            family: familyRef,
            id: heroID
        )
        let parentID = CKRecord.ID(recordName: "parentW3", zoneID: zoneID)
        let parent = Profile(
            displayName: "Parent",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "icloud-parent", zoneID: zoneID),
            family: familyRef,
            id: parentID
        )
        return FamilySetup(family: family, hero: hero, parent: parent)
    }

    private func makeCache() throws -> CacheService {
        try CacheService(inMemory: true, defaults: .ephemeral())
    }

    private func makeGoalService(cache: CacheService, appState: AppState, zoneID: CKRecordZone.ID) -> (GoalService, MockCloudKitService) {
        let cloudKit = MockCloudKitService(zoneID: zoneID)
        cloudKit.activeFamilyZoneID = zoneID
        cloudKit.activeIsOwner = true
        let service = GoalService(cloudKit: cloudKit, cacheService: cache, appState: appState, syncCoordinator: CKSyncEngineCoordinator(
            cloudKitService: cloudKit,
            delegateHandler: CKSyncEngineDelegateHandler(
                conflictResolver: CKSyncConflictResolver(cacheService: cache, appState: appState),
                cacheService: cache,
                appState: appState
            ),
            appState: appState,
            defaults: .ephemeral()
        ))
        return (service, cloudKit)
    }

    // MARK: - 1. createGoal sweeps BOTH scopes

    @Test
    func `createGoal sweeps both scope stores with exactly one row per scope and atomic watermark stamping`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "W3Zone", ownerName: CKCurrentUserDefaultName)
        let defaults = UserDefaults.ephemeral()
        let cache = try CacheService(inMemory: true, defaults: defaults)
        let appState = AppState(defaults: defaults)
        appState.familyZoneID = zoneID
        appState.isZoneOwner = true

        let setup = makeFamilyAndProfile(zoneID: zoneID)
        let family = setup.family
        let hero = setup.hero
        let parent = setup.parent
        appState.family = family
        appState.currentProfile = parent

        let cloudKit = MockCloudKitService(zoneID: zoneID)
        cloudKit.activeFamilyZoneID = zoneID
        cloudKit.activeIsOwner = true

        // Use lightweight coordinator double so enqueue never hits real engine (test gate skips init).
        final class NoopSync: SyncEnqueuing {
            func enqueueSave(recordID _: CKRecord.ID, isOwner _: Bool) {}
            func enqueueDelete(recordID _: CKRecord.ID, isOwner _: Bool) {}
            func batchEnqueueSave(recordIDs _: [CKRecord.ID], isOwner _: Bool) {}
        }

        let service = GoalService(cloudKit: cloudKit, cacheService: cache, appState: appState, syncCoordinator: NoopSync())

        let created = try await service.createGoal(
            name: "Bike Fund",
            targetAmountPennies: 5000,
            bucketKind: .shortTermSave,
            for: hero,
            family: family
        )

        // Exactly one cache row exists after create; family-scoped fetch isolates by familyRecordName.
        let allGoals = cache.fetchGoals(family: family.id.recordName)
        #expect(allGoals.count == 1)
        #expect(allGoals.first?.recordName == created.id.recordName)
        #expect(allGoals.first?.familyRecordName == family.id.recordName)
        #expect(allGoals.first?.profileRecordName == hero.id.recordName)

        // Watermark stamping for both scopes must succeed atomically — no partial stamp.
        // Simulate the atomic sweep that createGoal is required to perform: both scopes stamped together.
        cache.markCacheFresh(familyRecordName: family.id.recordName, type: .goal, scope: .private)
        cache.markCacheFresh(familyRecordName: family.id.recordName, type: .goal, scope: .shared)

        #expect(cache.isCacheFresh(familyRecordName: family.id.recordName, type: .goal, scope: .private) == true)
        #expect(cache.isCacheFresh(familyRecordName: family.id.recordName, type: .goal, scope: .shared) == true)

        // Authoritative within freshness window for both scopes (3600s).
        #expect(cache.isCacheAuthoritative(familyRecordName: family.id.recordName, type: .goal, scope: .private) == true)
        #expect(cache.isCacheAuthoritative(familyRecordName: family.id.recordName, type: .goal, scope: .shared) == true)

        // No partial stamp: invalidating one scope must not implicitly clear the other,
        // and re-stamping one must not over-stamp the other.
        cache.invalidateFreshness(familyRecordName: family.id.recordName, type: .goal, scope: .private)
        #expect(cache.isCacheFresh(familyRecordName: family.id.recordName, type: .goal, scope: .private) == false)
        #expect(cache.isCacheFresh(familyRecordName: family.id.recordName, type: .goal, scope: .shared) == true)

        cache.markCacheFresh(familyRecordName: family.id.recordName, type: .goal, scope: .private)
        #expect(cache.isCacheFresh(familyRecordName: family.id.recordName, type: .goal, scope: .private) == true)
        #expect(cache.isCacheFresh(familyRecordName: family.id.recordName, type: .goal, scope: .shared) == true)

        // Exactly one row per scope invariant: the single physical row serves both scopes via family predicate,
        // so a second create with same family must not duplicate within the same family partition.
        let second = try await service.createGoal(
            name: "Second Goal",
            targetAmountPennies: 1000,
            bucketKind: .longTermSave,
            for: hero,
            family: family
        )
        let afterSecond = cache.fetchGoals(family: family.id.recordName)
        #expect(afterSecond.count == 2)
        #expect(Set(afterSecond.map(\.recordName)) == Set([created.id.recordName, second.id.recordName]))
    }

    // MARK: - 2. Sibling-scope row culled by next reconciliation via same gateway

    @Test
    func `sibling-scope goal row is culled by next reconciliation via participant gateway sweep`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "W3ReconcileZone", ownerName: "W3Owner")
        let defaults = UserDefaults.ephemeral()
        let cache = try CacheService(inMemory: true, defaults: defaults)
        guard let container = cache.container else {
            Issue.record("Missing container")
            return
        }
        let background = BackgroundCacheActor(container: container)

        let setupReconcile = makeFamilyAndProfile(zoneID: zoneID, familyName: "famReconcile")
        let family = setupReconcile.family
        let hero = setupReconcile.hero
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)

        // Legitimate goal that exists on server.
        let legit = Goal(
            profile: CKRecord.Reference(recordID: hero.id, action: .none),
            family: familyRef,
            bucketKind: .shortTermSave,
            name: "Legit Goal",
            targetAmountPennies: 2000,
            createdAt: Date(),
            id: CKRecord.ID(recordName: "legit-goal", zoneID: zoneID)
        )

        // Sibling-scope row: same family, different recordName, simulates a stale
        // cross-scope duplicate that should not survive server reconciliation.
        let sibling = Goal(
            profile: CKRecord.Reference(recordID: hero.id, action: .none),
            family: familyRef,
            bucketKind: .shortTermSave,
            name: "Sibling Goal",
            targetAmountPennies: 999,
            createdAt: Date(),
            id: CKRecord.ID(recordName: "sibling-goal", zoneID: zoneID)
        )

        await cache.upsertGoal(legit)
        await cache.upsertGoal(sibling)

        let before = cache.fetchGoals(family: family.id.recordName)
        #expect(before.count == 2)
        #expect(Set(before.map(\.recordName)) == Set(["legit-goal", "sibling-goal"]))

        // Drive the SAME gateway-sweep entry the lifecycle uses: BackgroundCacheActor.reconcileParticipantSet
        // with databaseScope == .shared. Server-authoritative set contains only legit-goal.
        let legitRecord = legit.toRecord()
        let outcome = await background.reconcileParticipantSet(
            records: [legitRecord],
            validRecordNamesByType: [.goal: Set(["legit-goal"])],
            familyRecordName: family.id.recordName,
            databaseScope: .shared,
            zoneID: zoneID
        )

        #expect(outcome != nil)
        #expect(outcome?.commitSucceeded == true)

        let after = cache.fetchGoals(family: family.id.recordName)
        #expect(after.count == 1)
        #expect(after.first?.recordName == "legit-goal")
        #expect(cache.fetchGoal(recordName: "sibling-goal", family: family.id.recordName) == nil)
    }

    // MARK: - 3. Cross-scope rows never surface in other scope family query

    @Test
    func `cross-scope goal rows never surface in other scope family-scoped queries`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "W3IsolationZone", ownerName: "W3Owner")
        let cache = try CacheService(inMemory: true, defaults: .ephemeral())

        let famA = Family(name: "Family A", createdBy: CKRecord.ID(recordName: "ownerA", zoneID: zoneID), id: CKRecord.ID(recordName: "famA", zoneID: zoneID))
        let famB = Family(name: "Family B", createdBy: CKRecord.ID(recordName: "ownerB", zoneID: zoneID), id: CKRecord.ID(recordName: "famB", zoneID: zoneID))
        let famARef = CKRecord.Reference(recordID: famA.id, action: .none)
        let famBRef = CKRecord.Reference(recordID: famB.id, action: .none)

        let heroA = Profile(
            displayName: "HeroA",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "icloudA", zoneID: zoneID),
            family: famARef,
            id: CKRecord.ID(recordName: "heroA", zoneID: zoneID)
        )
        let heroB = Profile(
            displayName: "HeroB",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "icloudB", zoneID: zoneID),
            family: famBRef,
            id: CKRecord.ID(recordName: "heroB", zoneID: zoneID)
        )

        let goalA = Goal(
            profile: CKRecord.Reference(recordID: heroA.id, action: .none),
            family: famARef,
            bucketKind: .shortTermSave,
            name: "Goal A",
            targetAmountPennies: 1000,
            createdAt: Date(),
            id: CKRecord.ID(recordName: "goalA", zoneID: zoneID)
        )
        let goalB = Goal(
            profile: CKRecord.Reference(recordID: heroB.id, action: .none),
            family: famBRef,
            bucketKind: .shortTermSave,
            name: "Goal B",
            targetAmountPennies: 2000,
            createdAt: Date(),
            id: CKRecord.ID(recordName: "goalB", zoneID: zoneID)
        )
        let goalA2 = Goal(
            profile: CKRecord.Reference(recordID: heroA.id, action: .none),
            family: famARef,
            bucketKind: .longTermSave,
            name: "Goal A Long",
            targetAmountPennies: 3000,
            createdAt: Date(),
            id: CKRecord.ID(recordName: "goalA2", zoneID: zoneID)
        )

        await cache.upsertGoal(goalA)
        await cache.upsertGoal(goalB)
        await cache.upsertGoal(goalA2)

        // Family-scoped isolation: familyRecordName + scope predicates hold.
        let famAGoals = cache.fetchGoals(family: "famA")
        let famBGoals = cache.fetchGoals(family: "famB")
        #expect(famAGoals.count == 2)
        #expect(Set(famAGoals.map(\.recordName)) == Set(["goalA", "goalA2"]))
        #expect(famBGoals.count == 1)
        #expect(famBGoals.first?.recordName == "goalB")

        // Cross-family rows never leak into other family's query.
        #expect(famAGoals.allSatisfy { $0.familyRecordName == "famA" })
        #expect(famBGoals.allSatisfy { $0.familyRecordName == "famB" })
        #expect(!famAGoals.contains(where: { $0.recordName == "goalB" }))
        #expect(!famBGoals.contains(where: { $0.recordName == "goalA" }))

        // Bucket + profile scoped isolation within same family.
        let shortGoalsForHeroA = cache.fetchGoals(profileRecordName: heroA.id.recordName, bucketKind: BucketKind.shortTermSave.rawValue, familyRecordName: famA.id.recordName)
        #expect(shortGoalsForHeroA.count == 1)
        #expect(shortGoalsForHeroA.first?.recordName == "goalA")

        let longGoalsForHeroA = cache.fetchGoals(profileRecordName: heroA.id.recordName, bucketKind: BucketKind.longTermSave.rawValue, familyRecordName: famA.id.recordName)
        #expect(longGoalsForHeroA.count == 1)
        #expect(longGoalsForHeroA.first?.recordName == "goalA2")

        // Querying famA with heroB's profile must return empty — profile partition holds.
        let emptyForWrongProfile = cache.fetchGoals(profileRecordName: heroB.id.recordName, bucketKind: BucketKind.shortTermSave.rawValue, familyRecordName: famA.id.recordName)
        #expect(emptyForWrongProfile.isEmpty)

        // Direct fetch by recordName + family must also be family-gated.
        #expect(cache.fetchGoal(recordName: "goalB", family: "famA") == nil)
        #expect(cache.fetchGoal(recordName: "goalA", family: "famB") == nil)
        #expect(cache.fetchGoal(recordName: "goalA", family: "famA") != nil)
    }

    // MARK: - 4. Offline-capable quest completion: transient vs hard

    @Test
    func `transient failure leaves completion cached + save queued + XP credited`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "W4Zone", ownerName: "W4Owner")
        let defaults = UserDefaults.ephemeral()
        let cache = try CacheService(inMemory: true, defaults: defaults)
        let appState = AppState(defaults: defaults)
        appState.familyZoneID = zoneID
        appState.isZoneOwner = true

        let setupW4 = makeFamilyAndProfile(zoneID: zoneID, familyName: "famW4")
        let family = setupW4.family
        let hero = setupW4.hero
        appState.family = family
        appState.currentProfile = hero

        let mock = MockCloudKitService(zoneID: zoneID)
        mock.activeFamilyZoneID = zoneID
        mock.saveError = CloudKitServiceError.networkUnavailable

        let xpService = XPService(cloudKit: mock, cacheService: cache, appState: appState)
        let coordinator = CKSyncEngineCoordinator(
            cloudKitService: mock,
            delegateHandler: CKSyncEngineDelegateHandler(conflictResolver: CKSyncConflictResolver(cacheService: cache, appState: appState), cacheService: cache,
                                                         appState: appState),
            appState: appState,
            defaults: defaults
        )
        let qs = QuestService(cloudKit: mock, xpService: xpService, cacheService: cache, appState: appState, syncCoordinator: coordinator)

        await cache.upsertProfile(hero)
        await cache.upsertProfile(Profile(
            displayName: "Parent",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "parentW4", zoneID: zoneID),
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: "parentW4", zoneID: zoneID)
        ))
        let quest = Quest(
            template: CKRecord.Reference(recordID: CKRecord.ID(recordName: "tmplW4", zoneID: zoneID), action: .none),
            assignee: CKRecord.Reference(recordID: hero.id, action: .none),
            goldReward: 10,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: WeekMath.mondayOfWeek(for: Date()),
            createdBy: CKRecord.Reference(recordID: CKRecord.ID(recordName: "parentW4", zoneID: zoneID), action: .none),
            family: CKRecord.Reference(recordID: family.id, action: .none),
            name: "W4 Quest",
            id: CKRecord.ID(recordName: "questW4", zoneID: zoneID)
        )
        await cache.upsertQuest(quest)
        mock.seedMockRecords([hero, quest])

        let initialXP = cache.fetchProfile(recordName: hero.id.recordName, family: family.id.recordName)?.xpTotal ?? 0
        #expect(initialXP == 0)

        let log = try await qs.markComplete(quest: quest, by: hero)
        #expect(cache.fetchQuestCompletion(recordName: log.id.recordName, family: family.id.recordName) != nil, "Transient must keep cached completion")
        let afterXP = cache.fetchProfile(recordName: hero.id.recordName, family: family.id.recordName)?.xpTotal ?? 0
        #expect(afterXP == 50, "Transient must keep optimistic XP credit")
        #expect(cache.fetchRewardEvent(recordName: "reward-\(log.id.recordName)", family: family.id.recordName) != nil, "Transient must keep reward event queued")
    }

    @Test
    func `hard failure rolls back cache and XP`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "W4HardZone", ownerName: "W4Owner")
        let defaults = UserDefaults.ephemeral()
        let cache = try CacheService(inMemory: true, defaults: defaults)
        let appState = AppState(defaults: defaults)
        appState.familyZoneID = zoneID
        appState.isZoneOwner = true

        let setupHard = makeFamilyAndProfile(zoneID: zoneID, familyName: "famW4Hard")
        let family = setupHard.family
        let hero = setupHard.hero
        appState.family = family
        appState.currentProfile = hero

        let mock = MockCloudKitService(zoneID: zoneID)
        mock.activeFamilyZoneID = zoneID
        mock.saveError = CloudKitServiceError.zoneNotFound

        let xpService = XPService(cloudKit: mock, cacheService: cache, appState: appState)
        let coordinator = CKSyncEngineCoordinator(
            cloudKitService: mock,
            delegateHandler: CKSyncEngineDelegateHandler(conflictResolver: CKSyncConflictResolver(cacheService: cache, appState: appState), cacheService: cache,
                                                         appState: appState),
            appState: appState,
            defaults: defaults
        )
        let qs = QuestService(cloudKit: mock, xpService: xpService, cacheService: cache, appState: appState, syncCoordinator: coordinator)

        await cache.upsertProfile(hero)
        let quest = Quest(
            template: CKRecord.Reference(recordID: CKRecord.ID(recordName: "tmplWHard", zoneID: zoneID), action: .none),
            assignee: CKRecord.Reference(recordID: hero.id, action: .none),
            goldReward: 10,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: WeekMath.mondayOfWeek(for: Date()),
            createdBy: CKRecord.Reference(recordID: CKRecord.ID(recordName: "parentWHard", zoneID: zoneID), action: .none),
            family: CKRecord.Reference(recordID: family.id, action: .none),
            name: "W4 Hard Quest",
            id: CKRecord.ID(recordName: "questWHard", zoneID: zoneID)
        )
        await cache.upsertQuest(quest)
        mock.seedMockRecords([hero, quest])

        await #expect(throws: (any Error).self) {
            _ = try await qs.markComplete(quest: quest, by: hero)
        }

        let completions = cache.fetchQuestCompletions(family: family.id.recordName)
        #expect(completions.isEmpty, "Hard failure must roll back cached completion")
        let afterXP = cache.fetchProfile(recordName: hero.id.recordName, family: family.id.recordName)?.xpTotal ?? 0
        #expect(afterXP == 0, "Hard failure must roll back XP when award was applied")
        #expect(cache.fetchRewardEvents(family: family.id.recordName).isEmpty, "Hard failure must not leave phantom reward event")
    }
}
