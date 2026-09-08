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
        zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let mock = MockCloudKitService(zoneID: zoneID)
        cache = try CacheService(inMemory: true)
        appState = AppState()
        hero = Profile(
            displayName: "Test Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "u1", zoneID: zoneID),
            family: CKRecord.Reference(
                recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
            ),
            id: CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        )
        family = Family(
            name: "Test Family",
            creatorUserRecordName: "u1",
            payoutDay: .sunday,
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
        appState.currentProfile = hero
        appState.family = family
        appState.familyZoneID = zoneID
        // The engine never initializes under TestEnvironment, so enqueued
        // saves buffer in memory instead of reaching CloudKit.
        let handler = CKSyncEngineDelegateHandler(conflictResolver: CKSyncConflictResolver())
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
            id: CKRecord.ID(recordName: name, zoneID: zoneID)
        )))
        _ = cache.saveContext()
    }

    func entries() -> [LedgerEntryCache] {
        cache.fetchLedgerEntries(profileRecordName: hero.id.recordName, family: family.id.recordName)
    }
}
