//
//  TransferTestScaffold.swift
//  LootListTests
//
//  Shared test scaffold for the treasury bucket-transfer flow.
//

import CloudKit
import Foundation
@testable import LootList

/// Scaffold for the treasury bucket-transfer flow: a self-owned hero
/// session over an in-memory cache with a buffered (engine-less) sync
/// coordinator, so transfers never touch the network.
@MainActor
struct TransferTestScaffold {
    let zoneID: CKRecordZone.ID
    let appState: AppState
    let buckets: BucketService
    let cache: CacheService
    let hero: Profile
    let family: Family
    private let profileRef: CKRecord.Reference
    private let familyRef: CKRecord.Reference

    init() throws {
        zoneID = ExhaustiveCacheFixtures.sharedZoneID
        let mock = MockCloudKitService(zoneID: zoneID)
        cache = try CacheService(inMemory: true)
        appState = AppState()
        hero = ExhaustiveCacheFixtures.sharedHero(zoneID: zoneID)
        family = ExhaustiveCacheFixtures.sharedFamily(zoneID: zoneID, name: "Test Family", creatorUserRecordName: "u1")
        appState.currentProfile = hero
        appState.family = family
        appState.familyZoneID = zoneID
        // WHY app-owned resolver persists merges against the test cache/session.
        let handler = ExhaustiveCacheFixtures.appOwnedHandler(cache: cache, appState: appState)
        let coordinator = CKSyncEngineCoordinator(cloudKitService: mock, delegateHandler: handler, appState: appState)
        buckets = BucketService(cacheService: cache, syncCoordinator: coordinator, appState: appState)
        profileRef = CKRecord.Reference(recordID: hero.id, action: .none)
        familyRef = CKRecord.Reference(recordID: family.id, action: .none)
    }

    func seed(_ name: String,
              amount: Int64,
              source: String,
              bucketKind: String?,
              fromBucket: String? = nil,
              toBucket: String? = nil)
    {
        cache.context?.insert(LedgerEntryCache(from: LedgerEntry(
            profile: profileRef,
            amount: amount,
            description: name,
            source: source,
            bucketKind: bucketKind,
            fromBucket: fromBucket,
            toBucket: toBucket,
            family: familyRef,
            id: ExhaustiveCacheFixtures.id(name, zoneID: zoneID)
        )))
        _ = cache.saveContext()
    }

    func entries() -> [LedgerEntryCache] {
        cache.fetchLedgerEntries(profileRecordName: hero.id.recordName, family: family.id.recordName)
    }
}
