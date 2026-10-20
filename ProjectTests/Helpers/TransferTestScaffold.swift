//
//  TransferTestScaffold.swift
//  LootListTests
//
//  Shared test scaffold for the treasury bucket-transfer flow.
//

import CloudKit
import Foundation
@testable import LootList

/// Test-only flattened spending row mirroring grouped splits for parity assertions.
struct SpendingLogRow: Identifiable, Equatable {
    let id: String
    let amount: Int64
    let description: String
    let location: String?
    let date: Date
    let source: String
    let rawCache: LedgerEntryCache?

    init(id: String,
         amount: Int64,
         description: String,
         location: String? = nil,
         date: Date,
         source: String,
         rawCache: LedgerEntryCache? = nil)
    {
        self.id = id
        self.amount = amount
        self.description = description
        self.location = location
        self.date = date
        self.source = source
        self.rawCache = rawCache
    }

    var formattedAmount: String {
        CurrencyFormatter.string(pennies: amount)
    }

    var bucketKind: String? {
        rawCache?.bucketKind
    }

    var bucketKindEnum: BucketKind? {
        bucketKind.flatMap { BucketKind(rawValue: $0) }
    }
}

/// Test-only flatten of grouped splits to rows so parity tests share one order.
enum LedgerRowFactory {
    @MainActor static func flattenedRows(from groups: [TransactionGroup], cacheByName: [String: LedgerEntryCache]) -> [SpendingLogRow] {
        var rows: [SpendingLogRow] = []
        rows.reserveCapacity(groups.reduce(0) { $0 + $1.splits.count })
        for group in groups {
            for split in group.splits {
                rows.append(SpendingLogRow(
                    id: split.recordName,
                    amount: split.amount,
                    description: split.entryDescription,
                    location: split.location,
                    date: split.date,
                    source: split.source,
                    rawCache: cacheByName[split.recordName]
                ))
            }
        }
        return rows
    }
}

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
        buckets = BucketService(
            cacheService: cache,
            syncCoordinator: coordinator,
            appState: appState,
            cloudKit: mock,
            shortDrawdown: { (_: Int64, _: Profile, _: Family, _: String, _: Date) async throws in }
        )
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
