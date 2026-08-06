//
//  OptimisticRollbackTests+InFlight.swift
//  LootList
//
//  Created by Ben Mackin on 8/05/26.
//

import CloudKit
import Foundation
@testable import LootList
import SwiftData
import Testing

// MARK: - In-flight mutation registry guards optimistic writes from background sync

extension OptimisticRollbackTests {
    @Test
    func `background batch upsert does not clobber optimistically-written in-flight row`() async throws {
        let zoneID = makeZoneID()
        let cache = try CacheService(inMemory: true)
        let container = try #require(cache.container)
        let registry = cache.inFlightRegistry
        let backgroundCache = BackgroundCacheActor(container: container, inFlightRegistry: registry)

        let (originalQuest, questID) = makeOptimisticQuest(zoneID)
        cache.upsertQuest(originalQuest)

        // Optimistic write: the author's in-flight values are now in the cache.
        var optimisticQuest = originalQuest
        optimisticQuest.name = "Optimistic Quest"
        optimisticQuest.goldReward = 99.0
        cache.upsertQuest(optimisticQuest)

        // The mutation is still in flight (local upsert → await cloudKit.save).
        await registry.register(questID.recordName)

        // A background sync arrives mid-mutation carrying stale server data.
        await backgroundCache.batchUpsertQuests(
            [originalQuest],
            familyRecordName: originalQuest.family.recordID.recordName
        )

        // The optimistically-written row must survive the sync untouched.
        let restored = try #require(
            try fetchCachedQuest(container, recordName: questID.recordName, zoneID: zoneID)
        )
        #expect(
            restored.name == "Optimistic Quest",
            "In-flight row must not be clobbered by a background batchUpsert"
        )
        #expect(
            restored.goldReward == 99.0,
            "In-flight row must keep the optimistic gold after a background batchUpsert"
        )
    }

    @Test
    func `background batch upsert applies normally after mutation deregisters`() async throws {
        let zoneID = makeZoneID()
        let cache = try CacheService(inMemory: true)
        let container = try #require(cache.container)
        let registry = cache.inFlightRegistry
        let backgroundCache = BackgroundCacheActor(container: container, inFlightRegistry: registry)

        let (originalQuest, questID) = makeOptimisticQuest(zoneID)
        cache.upsertQuest(originalQuest)

        var optimisticQuest = originalQuest
        optimisticQuest.name = "Optimistic Quest"
        optimisticQuest.goldReward = 99.0
        cache.upsertQuest(optimisticQuest)

        // The mutation is in flight, then settles (success or terminal failure):
        // the record is deregistered once the CloudKit save settles.
        await registry.register(questID.recordName)
        await registry.deregister(questID.recordName)

        // A sync arriving after deregistration applies server data normally.
        await backgroundCache.batchUpsertQuests(
            [originalQuest],
            familyRecordName: originalQuest.family.recordID.recordName
        )

        let restored = try #require(
            try fetchCachedQuest(container, recordName: questID.recordName, zoneID: zoneID)
        )
        #expect(
            restored.name == "Original Quest",
            "Sync writes must apply normally after the mutation deregisters"
        )
        #expect(
            restored.goldReward == 10.0,
            "Sync writes must restore server gold after the mutation deregisters"
        )
    }

    @Test
    func `purge missing does not delete a row under an active optimistic mutation`() async throws {
        let zoneID = makeZoneID()
        let cache = try CacheService(inMemory: true)
        let container = try #require(cache.container)
        let registry = cache.inFlightRegistry
        let backgroundCache = BackgroundCacheActor(container: container, inFlightRegistry: registry)

        let familyRef = makeFamilyRef(zoneID)
        let monday = WeekMath.mondayOfWeek(for: Date())
        let templateRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none
        )
        let heroRef = CKRecord.Reference(recordID: makeHero(zoneID).id, action: .none)

        // A quest whose save has settled — not under any optimistic mutation.
        let settledID = CKRecord.ID(recordName: "quest2", zoneID: zoneID)
        let settledQuest = Quest(
            template: templateRef,
            assignee: heroRef,
            goldReward: 5.0,
            xpReward: 10,
            scheduleType: .weeklyFlexible,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: monday,
            createdBy: familyRef,
            family: familyRef,
            name: "Settled Quest",
            id: settledID
        )
        cache.upsertQuest(settledQuest)

        // A quest under an active optimistic mutation: the local cache write is
        // done but the CloudKit save has not settled (or settled and the
        // author's post-save re-upsert has not deregistered yet).
        let (optimisticQuest, optimisticID) = makeOptimisticQuest(zoneID)
        cache.upsertQuest(optimisticQuest)
        await registry.register(optimisticID.recordName)

        // Full-sync purge: `validRecordNames` is a CloudKit query snapshot
        // taken before either quest existed, so neither appears in it.
        await backgroundCache.purgeMissingQuests(
            validRecordNames: [],
            familyRecordName: familyRef.recordID.recordName
        )

        // The row under an active optimistic mutation must survive the purge.
        let survived = try #require(
            try fetchCachedQuest(container, recordName: optimisticID.recordName, zoneID: zoneID)
        )
        #expect(
            survived.name == "Original Quest",
            "A row under an active optimistic mutation must survive a purgeMissing pass"
        )

        // The deregistered row is purged normally.
        #expect(
            try fetchCachedQuest(container, recordName: settledID.recordName, zoneID: zoneID) == nil,
            "A deregistered row absent from the server snapshot must be purged"
        )
    }

    // MARK: - Incremental-sync deletion skips rows under an active optimistic mutation

    @Test
    func `delete record does not delete a row under an active optimistic mutation`() async throws {
        let zoneID = makeZoneID()
        let cache = try CacheService(inMemory: true)
        let container = try #require(cache.container)
        let registry = cache.inFlightRegistry
        let backgroundCache = BackgroundCacheActor(container: container, inFlightRegistry: registry)

        let (optimisticQuest, questID) = makeOptimisticQuest(zoneID)
        cache.upsertQuest(optimisticQuest)

        // The mutation is still in flight (local upsert → await cloudKit.save).
        await registry.register(questID.recordName)

        // An incremental sync delivers a server-side deletion for the same
        // record while the mutation is in flight.
        await backgroundCache.deleteRecord(recordName: questID.recordName, type: .quest)

        // The optimistically-written row must survive the sync deletion — the
        // author's rollback (or post-save re-upsert) reconciles it once the
        // save settles, and deleting it first would let the rollback
        // resurrect a record that no longer exists server-side.
        let survived = try #require(
            try fetchCachedQuest(container, recordName: questID.recordName, zoneID: zoneID)
        )
        #expect(
            survived.name == "Original Quest",
            "A row under an active optimistic mutation must survive a sync deletion"
        )

        // Once the save settles (deregister), the deletion applies normally.
        await registry.deregister(questID.recordName)
        await backgroundCache.deleteRecord(recordName: questID.recordName, type: .quest)
        #expect(
            try fetchCachedQuest(container, recordName: questID.recordName, zoneID: zoneID) == nil,
            "A deregistered row with a server-side deletion must be deleted"
        )
    }

    // MARK: - .notFound save failure during a concurrent delete invalidates, never resurrects (no zombie quest)

    @Test
    func `notFound save failure during concurrent delete invalidates instead of resurrecting snapshot`() async throws {
        let zoneID = makeZoneID()
        let cloudKit = NotFoundCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let container = try #require(cache.container)
        let xpService = XPService(cloudKit: cloudKit, cacheService: cache)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService)
        questService.cacheService = cache

        let familyRef = makeFamilyRef(zoneID)
        let hero = makeHero(zoneID)
        let parent = makeParent(zoneID)
        // updateQuest is parent-only — wire an authenticated parent session.
        let appState = AppState()
        questService.appState = appState
        appState.currentProfile = parent
        let monday = WeekMath.mondayOfWeek(for: Date())
        let templateRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none
        )
        let questID = CKRecord.ID(recordName: "quest1", zoneID: zoneID)

        // Seed the original quest in cache — the pre-mutation snapshot.
        let originalQuest = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(recordID: hero.id, action: .none),
            goldReward: 10.0,
            xpReward: 20,
            scheduleType: .weeklyFlexible,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: monday,
            createdBy: familyRef,
            family: familyRef,
            name: "Original Quest",
            id: questID
        )
        cache.upsertQuest(originalQuest)

        // Another device deletes the quest on the server; an incremental sync
        // delivers that deletion WHILE our optimistic mutation is in flight.
        // The in-flight registry guard keeps the sync's hands off the
        // optimistically-written row.
        let registry = cache.inFlightRegistry
        let backgroundCache = BackgroundCacheActor(container: container, inFlightRegistry: registry)
        await registry.register(questID.recordName)
        await backgroundCache.deleteRecord(recordName: questID.recordName, type: .quest)
        let survivedSync = try #require(
            try fetchCachedQuest(container, recordName: questID.recordName, zoneID: zoneID)
        )
        #expect(
            survivedSync.name == "Original Quest",
            "In-flight rows must survive a sync deletion"
        )

        // The mutation's save settles with `.notFound`: the record no longer
        // exists server-side. The rollback must invalidate — never restore the
        // pre-mutation snapshot, which would resurrect a zombie quest.
        var updatedQuest = originalQuest
        updatedQuest.name = "Modified Quest"
        updatedQuest.goldReward = 99.0

        do {
            _ = try await questService.updateQuest(updatedQuest)
            #expect(Bool(false), "Expected save to throw")
        } catch {
            #expect(error is CloudKitServiceError)
        }

        // No zombie row: the cache must not contain the pre-mutation snapshot.
        #expect(
            cache.fetchQuests(family: familyRef.recordID.recordName).isEmpty,
            "A .notFound save failure during a concurrent delete must invalidate, not restore the snapshot"
        )
    }
}
