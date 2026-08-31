//
//  CacheFirstTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/30/26.
//

import CloudKit
@testable import LootList
import Testing

@MainActor
struct CacheFirstTests {
    @Test
    func `cacheFirst returns empty cached on CloudKit failure for brand-new hero`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cache = try CacheService(inMemory: true)
        let appState = AppState.testState()
        appState.cacheService = cache
        appState.familyZoneID = zoneID
        appState.isZoneOwner = true
        appState.family = Family(name: "Guild", createdBy: CKRecord.ID(recordName: "owner", zoneID: zoneID), id: CKRecord.ID(recordName: "fam1", zoneID: zoneID))
        let family = try #require(appState.family)
        // No freshness stamp — cache is stale and empty (brand-new hero).
        let failingCloudKit = FailingCloudKitService(zoneID: zoneID)
        let coordinator = TestSyncCoordinatorSpy(cache: cache, appState: appState, cloudKit: failingCloudKit).coordinator

        // CacheFirst must not throw when cached is empty — brand-new hero tolerance.
        let result: [LedgerEntry] = try await CacheFirst.cacheFirst(
            type: .ledgerEntry,
            family: family,
            cacheService: cache,
            appState: appState,
            fetchCache: { familyName in
                cache.fetchLedgerEntries(family: familyName)
            },
            map: { cache in
                cache.toLedgerEntry(zoneID: zoneID)
            },
            query: {
                throw CloudKitServiceError.networkUnavailable
            },
            hydrate: { _ in
                await coordinator.delegateHandler.hydrateFromQuery(models: [LedgerEntry](), databaseScope: appState.activeDatabaseScope, zoneID: zoneID)
            }
        )
        #expect(result.isEmpty)
    }

    @Test
    func `cacheFirst returns stale non-empty cached on CloudKit failure`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cache = try CacheService(inMemory: true)
        let appState = AppState.testState()
        appState.cacheService = cache
        appState.familyZoneID = zoneID
        appState.isZoneOwner = true
        let family = Family(name: "Guild", createdBy: CKRecord.ID(recordName: "owner", zoneID: zoneID), id: CKRecord.ID(recordName: "fam1", zoneID: zoneID))
        appState.family = family
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let profileID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        let entry = LedgerEntry(
            profile: CKRecord.Reference(recordID: profileID, action: .none),
            amount: 10,
            description: "Seed",
            date: Date(),
            source: "quest",
            family: familyRef,
            id: CKRecord.ID(recordName: "entry1", zoneID: zoneID)
        )
        await cache.upsertLedgerEntry(entry)
        // Stale cache (no freshness) with one entry.
        let failingCloudKit = FailingCloudKitService(zoneID: zoneID)
        let coordinator = TestSyncCoordinatorSpy(cache: cache, appState: appState, cloudKit: failingCloudKit).coordinator

        let result: [LedgerEntry] = try await CacheFirst.cacheFirst(
            type: .ledgerEntry,
            family: family,
            cacheService: cache,
            appState: appState,
            fetchCache: { familyName in
                cache.fetchLedgerEntries(family: familyName)
            },
            map: { cache in
                cache.toLedgerEntry(zoneID: zoneID)
            },
            query: {
                throw CloudKitServiceError.networkUnavailable
            },
            hydrate: { _ in
                await coordinator.delegateHandler.hydrateFromQuery(models: [LedgerEntry](), databaseScope: appState.activeDatabaseScope, zoneID: zoneID)
            }
        )
        #expect(result.count == 1)
        #expect(result.first?.amount == 10)
    }
}

private final class FailingCloudKitService: MockCloudKitService {
    override func query<T: CloudKitRecord>(_: T.Type, predicate _: NSPredicate, in _: CKRecordZone.ID?, sortDescriptors _: [NSSortDescriptor]?,
                                           using _: CKDatabase?) async throws -> [T]
    {
        throw CloudKitServiceError.networkUnavailable
    }
}
