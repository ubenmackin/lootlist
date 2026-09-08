//
//  TransferNonceRegressionTests.swift
//  LootList
//
//  Created by Ben Mackin on 9/08/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct TransferNonceRegressionTests {
    private let zoneID = CKRecordZone.ID(zoneName: "NonceZone", ownerName: "NonceOwner")

    private func id(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    private func ref(_ name: String) -> CKRecord.Reference {
        CKRecord.Reference(recordID: id(name), action: .none)
    }

    @Test
    func `keyed transfer keeps transfer-profile-transferID format`() {
        // WHY: keyed retries must dedupe via CKSyncEngine on the same recordName.
        let name = DeterministicRecordID.transfer(profileRecordName: "hero1", transferID: "1750000000000-400-spend-shortTermSave")
        #expect(name == "transfer-hero1-1750000000000-400-spend-shortTermSave")
    }

    @Test
    func `same divergent payload converges to the same extended ID across devices`() async throws {
        // WHY: offline devices must agree on the fallback name without shared device-local state.
        let baseTransferID = "1750000000000-400-spend-shortTermSave"
        let baseRecordName = DeterministicRecordID.transfer(profileRecordName: "hero1", transferID: baseTransferID)
        func extendedOnFreshDevice() async throws -> String {
            let scaffold = try TransferTestScaffold()
            scaffold.seed("l-spend-in", amount: 10000, source: "quest", bucketKind: BucketKind.spend.rawValue)
            await scaffold.cache.upsertLedgerEntry(LedgerEntry(
                profile: CKRecord.Reference(recordID: scaffold.hero.id, action: .none),
                amount: 999,
                description: "Transfer from \(BucketKind.spend.displayName) to \(BucketKind.shortTermSave.displayName)",
                date: Date(timeIntervalSince1970: 1_750_000_000),
                source: LedgerSource.transfer.rawValue,
                bucketKind: BucketKind.shortTermSave.rawValue,
                fromBucket: BucketKind.spend.rawValue,
                toBucket: BucketKind.shortTermSave.rawValue,
                family: CKRecord.Reference(recordID: scaffold.family.id, action: .none),
                id: CKRecord.ID(recordName: baseRecordName, zoneID: scaffold.zoneID)
            ))
            let entry = try await scaffold.buckets.transfer(
                from: .spend,
                to: .shortTermSave,
                amount: 400,
                profile: scaffold.hero,
                family: scaffold.family,
                transferID: baseTransferID
            )
            return entry.id.recordName
        }
        let first = try await extendedOnFreshDevice()
        let second = try await extendedOnFreshDevice()
        #expect(first == second)
        #expect(first != baseRecordName)
        #expect(first.hasPrefix(baseRecordName + "-"))
        #expect(first.hasPrefix("transfer-hero1-"))
    }

    @Test
    func `divergent collisions fork distinctly while identical retries dedupe`() async throws {
        // WHY: each divergent payload must own a distinct fallback name while replays hit the same row.
        let baseTransferID = "1750000000000-400-spend-shortTermSave"
        let baseRecordName = DeterministicRecordID.transfer(profileRecordName: "hero1", transferID: baseTransferID)
        let scaffold = try TransferTestScaffold()
        scaffold.seed("l-spend-in", amount: 10000, source: "quest", bucketKind: BucketKind.spend.rawValue)
        await scaffold.cache.upsertLedgerEntry(LedgerEntry(
            profile: CKRecord.Reference(recordID: scaffold.hero.id, action: .none),
            amount: 999,
            description: "Transfer from \(BucketKind.spend.displayName) to \(BucketKind.shortTermSave.displayName)",
            date: Date(timeIntervalSince1970: 1_750_000_000),
            source: LedgerSource.transfer.rawValue,
            bucketKind: BucketKind.shortTermSave.rawValue,
            fromBucket: BucketKind.spend.rawValue,
            toBucket: BucketKind.shortTermSave.rawValue,
            family: CKRecord.Reference(recordID: scaffold.family.id, action: .none),
            id: CKRecord.ID(recordName: baseRecordName, zoneID: scaffold.zoneID)
        ))
        let first = try await scaffold.buckets.transfer(
            from: .spend,
            to: .shortTermSave,
            amount: 400,
            profile: scaffold.hero,
            family: scaffold.family,
            transferID: baseTransferID
        )
        let second = try await scaffold.buckets.transfer(
            from: .spend,
            to: .shortTermSave,
            amount: 600,
            profile: scaffold.hero,
            family: scaffold.family,
            transferID: baseTransferID
        )
        #expect(first.id.recordName != baseRecordName)
        #expect(second.id.recordName != baseRecordName)
        #expect(first.id.recordName != second.id.recordName)
        #expect(first.id.recordName.hasPrefix(baseRecordName + "-"))
        #expect(second.id.recordName.hasPrefix(baseRecordName + "-"))
        let countAfterForks = scaffold.entries().count
        await #expect(throws: BucketServiceError.duplicateTodayTransfer) {
            _ = try await scaffold.buckets.transfer(
                from: .spend,
                to: .shortTermSave,
                amount: 400,
                profile: scaffold.hero,
                family: scaffold.family,
                transferID: baseTransferID
            )
        }
        #expect(scaffold.entries().count == countAfterForks)
    }

    @Test
    func `freshness stamps per type without partial over-stamp`() throws {
        // WHY: failed types must stay stale so the next pass re-fetches only them.
        let cache = try CacheService(inMemory: true, defaults: .ephemeral())
        cache.markCacheFresh(familyRecordName: "fam1", type: .goal, scope: .private)
        #expect(cache.isCacheFresh(familyRecordName: "fam1", type: .goal, scope: .private) == true)
        #expect(cache.isCacheFresh(familyRecordName: "fam1", type: .goal, scope: .shared) == false)
        cache.markCacheFresh(familyRecordName: "fam1", type: .goal, scope: .shared)
        #expect(cache.isCacheFresh(familyRecordName: "fam1", type: .goal, scope: .shared) == true)
        cache.invalidateFreshness(familyRecordName: "fam1", type: .goal, scope: .private)
        #expect(cache.isCacheFresh(familyRecordName: "fam1", type: .goal, scope: .private) == false)
        #expect(cache.isCacheFresh(familyRecordName: "fam1", type: .goal, scope: .shared) == true)
    }

    @Test
    func `empty snapshot predicate aborts prune while partial snapshot proceeds`() {
        // WHY: unsettled scope reads empty and must never prune pending local rows.
        let empty: [CachedRecordType: Set<String>] = [.goal: [], .ledgerEntry: []]
        #expect(empty.values.allSatisfy(\.isEmpty) == true)
        let partial: [CachedRecordType: Set<String>] = [.goal: ["g1"], .ledgerEntry: []]
        #expect(partial.values.allSatisfy(\.isEmpty) == false)
    }

    @Test
    func `cacheFirst falls back only on transient network errors`() async throws {
        // WHY: persistent server errors must surface for StaleDataBanner instead of masking as stale cache.
        // WHY ephemeral defaults: shared standard watermarks could mark this family fresh and skip the query so no error throws.
        let cache = try CacheService(inMemory: true, defaults: .ephemeral())
        let appState = AppState.testState()
        appState.cacheService = cache
        appState.familyZoneID = zoneID
        appState.isZoneOwner = true
        let family = Family(name: "Guild", creatorUserRecordName: "owner", id: id("fam1"))
        appState.family = family
        let transient: [LedgerEntry] = try await CacheFirst.cacheFirst(
            type: .ledgerEntry,
            family: family,
            cacheService: cache,
            appState: appState,
            fetchCache: { (_: String) -> [LedgerEntryCache] in [] },
            map: { $0.toLedgerEntry(zoneID: zoneID) },
            query: { () async throws -> [LedgerEntry] in throw CloudKitServiceError.networkUnavailable },
            hydrate: { (_: [LedgerEntry]) async in }
        )
        #expect(transient.isEmpty)
        let retryable: [LedgerEntry] = try await CacheFirst.cacheFirst(
            type: .ledgerEntry,
            family: family,
            cacheService: cache,
            appState: appState,
            fetchCache: { (_: String) -> [LedgerEntryCache] in [] },
            map: { $0.toLedgerEntry(zoneID: zoneID) },
            query: { () async throws -> [LedgerEntry] in throw CloudKitServiceError.retryable(attempt: 1, code: nil) },
            hydrate: { (_: [LedgerEntry]) async in }
        )
        #expect(retryable.isEmpty)
        // WHY: exhausted budget is transient retry fallout, so it falls back like other network errors.
        let exhausted: [LedgerEntry] = try await CacheFirst.cacheFirst(
            type: .ledgerEntry,
            family: family,
            cacheService: cache,
            appState: appState,
            fetchCache: { (_: String) -> [LedgerEntryCache] in [] },
            map: { $0.toLedgerEntry(zoneID: zoneID) },
            query: { () async throws -> [LedgerEntry] in throw CloudKitServiceError.exhaustedBudget(attempt: 3) },
            hydrate: { (_: [LedgerEntry]) async in }
        )
        #expect(exhausted.isEmpty)
        await #expect(throws: CloudKitServiceError.notFound("x")) {
            _ = try await CacheFirst.cacheFirst(
                type: .ledgerEntry,
                family: family,
                cacheService: cache,
                appState: appState,
                fetchCache: { (_: String) -> [LedgerEntryCache] in [] },
                map: { $0.toLedgerEntry(zoneID: zoneID) },
                query: { () async throws -> [LedgerEntry] in throw CloudKitServiceError.notFound("x") },
                hydrate: { (_: [LedgerEntry]) async in }
            ) as [LedgerEntry]
        }
        await #expect(throws: CloudKitServiceError.serverRecordChanged) {
            _ = try await CacheFirst.cacheFirst(
                type: .ledgerEntry,
                family: family,
                cacheService: cache,
                appState: appState,
                fetchCache: { (_: String) -> [LedgerEntryCache] in [] },
                map: { $0.toLedgerEntry(zoneID: zoneID) },
                query: { () async throws -> [LedgerEntry] in throw CloudKitServiceError.serverRecordChanged },
                hydrate: { (_: [LedgerEntry]) async in }
            ) as [LedgerEntry]
        }
    }

    @Test
    func `ledger delete captures identity before invalidate and enqueues tombstone`() async throws {
        // WHY: tombstone ID must survive local row removal or the server row leaks.
        let cache = try CacheService(inMemory: true)
        let appState = AppState.testState()
        let mock = MockCloudKitService(zoneID: zoneID)
        mock.activeFamilyZoneID = zoneID
        mock.activeIsOwner = true
        let hero = Profile(displayName: "Hero", role: .hero, iCloudUserID: id("u1"), family: ref("fam1"), id: id("hero1"))
        let family = Family(name: "Fam", creatorUserRecordName: "u1", id: id("fam1"))
        appState.currentProfile = hero
        appState.family = family
        appState.familyZoneID = zoneID
        appState.isZoneOwner = true
        let entry = LedgerEntry(
            profile: ref("hero1"),
            amount: -500,
            description: "Snack",
            source: LedgerSource.manual.rawValue,
            bucketKind: BucketKind.spend.rawValue,
            family: ref("fam1"),
            id: id("led-delete-1")
        )
        await cache.upsertLedgerEntry(entry)
        #expect(cache.fetchLedgerEntry(recordName: "led-delete-1", family: "fam1") != nil)
        let recorder = RecordingSync()
        let service = LedgerService(cloudKit: mock, cacheService: cache, appState: appState, syncCoordinator: recorder)
        try await service.delete(entry)
        #expect(cache.fetchLedgerEntry(recordName: "led-delete-1", family: "fam1") == nil)
        #expect(recorder.deleted == ["led-delete-1"])
    }

    @Test
    func `recordBridge fails closed on empty and mismatched identities`() async throws {
        // WHY: unresolvable deletes must retain pending saves for retry, never confirm.
        let cache = try CacheService(inMemory: true)
        let quest = Quest(
            template: ref("tpl1"),
            assignee: ref("hero1"),
            goldReward: 5,
            xpReward: 10,
            scheduleType: .weeklyFlexible,
            weekOf: Date(),
            createdBy: ref("parent1"),
            family: ref("fam1"),
            name: "Row",
            id: id("quest-fail-closed")
        )
        await cache.upsertQuest(quest)
        // WHY seed owning family: mismatched-family retention rides indexed lookup in the owning family.
        await cache.upsertFamily(Family(name: "Fam1", creatorUserRecordName: "u1", id: id("fam1")))
        // WHY string init: CKRecord.ID with an empty recordName throws before the code under test runs.
        let emptyIdentity = ScopedRecordIdentity(databaseScope: .private, zoneName: zoneID.zoneName, zoneOwnerName: zoneID.ownerName, recordName: "", familyRecordName: "fam1")
        #expect(RecordBridge.record(for: emptyIdentity, cacheService: cache) == nil)
        #expect(RecordBridge.confirmedLocalDeletion(for: emptyIdentity, cacheService: cache) == false)
        let wrongFamily = ScopedRecordIdentity(databaseScope: .private, zoneID: zoneID, recordID: id("quest-fail-closed"), familyRecordName: "otherFam")
        #expect(RecordBridge.record(for: wrongFamily, cacheService: cache) == nil)
        #expect(RecordBridge.confirmedLocalDeletion(for: wrongFamily, cacheService: cache) == false)
    }
}

@MainActor
private final class RecordingSync: SyncEnqueuing {
    var deleted: [String] = []
    func enqueueSave(recordID _: CKRecord.ID, isOwner _: Bool) {}
    func enqueueDelete(recordID: CKRecord.ID, isOwner _: Bool) {
        deleted.append(recordID.recordName)
    }

    func batchEnqueueSave(recordIDs _: [CKRecord.ID], isOwner _: Bool) {}
}
