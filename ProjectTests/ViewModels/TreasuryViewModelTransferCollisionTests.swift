//
//  TreasuryViewModelTransferCollisionTests.swift
//  LootList
//
//  Created by Ben Mackin on 9/6/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct TreasuryViewModelTransferCollisionTests {
    /// Scaffold for the treasury bucket-transfer flow: a self-owned hero
    /// session over an in-memory cache with a buffered (engine-less) sync
    /// coordinator, so transfers never touch the network.
    @MainActor
    private struct TransferScaffold {
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
                createdBy: CKRecord.ID(recordName: "u1", zoneID: zoneID),
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
                  amount: Double,
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

    @Test
    func `multiple transfers on same day between same bucket pair succeed`() async throws {
        let scaffold = try TransferScaffold()
        scaffold.seed("l-spend-in", amount: 20.00, source: "quest", bucketKind: BucketKind.spend.rawValue)

        let now = Date()
        let entry1 = try await scaffold.buckets.transfer(
            from: .spend, to: .shortTermSave, amount: 4.00,
            profile: scaffold.hero, family: scaffold.family,
            at: now
        )
        let entry2 = try await scaffold.buckets.transfer(
            from: .spend, to: .shortTermSave, amount: 6.00,
            profile: scaffold.hero, family: scaffold.family,
            at: now.addingTimeInterval(1)
        )

        #expect(entry1.id.recordName != entry2.id.recordName)
        #expect(scaffold.entries().count == 3) // 1 seed + 2 transfers
        let balances = scaffold.buckets.bucketBalances(profileRecordName: "hero1", familyRecordName: "fam1")
        #expect(balances[.spend] == 10.00)
        #expect(balances[.shortTermSave] == 10.00)

        // WHY distinct by construction: same instant but different cents (200c vs
        // 400c) mints a different base ID, so this never hits the collision branch.
        let entry3 = try await scaffold.buckets.transfer(
            from: .spend, to: .shortTermSave, amount: 2.00,
            profile: scaffold.hero, family: scaffold.family,
            at: now
        )
        #expect(entry3.id.recordName != entry1.id.recordName)
        #expect(scaffold.entries().count == 4)
        let finalBalances = scaffold.buckets.bucketBalances(profileRecordName: "hero1", familyRecordName: "fam1")
        #expect(finalBalances[.spend] == 8.00)
        #expect(finalBalances[.shortTermSave] == 12.00)
    }

    @Test
    func `same millisecond same amount replay converges without a duplicate row`() async throws {
        let scaffold = try TransferScaffold()
        scaffold.seed("l-spend-in", amount: 20.00, source: "quest", bucketKind: BucketKind.spend.rawValue)

        let now = Date()
        let entry1 = try await scaffold.buckets.transfer(
            from: .spend, to: .shortTermSave, amount: 4.00,
            profile: scaffold.hero, family: scaffold.family,
            at: now
        )
        let countAfterFirst = scaffold.entries().count
        let balancesAfterFirst = scaffold.buckets.bucketBalances(profileRecordName: "hero1", familyRecordName: "fam1")

        // WHY replay-safe: same instant, cents, and pair mint the same base ID,
        // so a retry must converge instead of forking a duplicate row.
        do {
            let replay = try await scaffold.buckets.transfer(
                from: .spend, to: .shortTermSave, amount: 4.00,
                profile: scaffold.hero, family: scaffold.family,
                at: now
            )
            // WHY idempotent return: the retry resolves to the original record.
            #expect(replay.id.recordName == entry1.id.recordName)
        } catch let error as BucketServiceError {
            // WHY deterministic duplicate: rejecting the identical retry with the
            // same error is also replay-safe while no row is added.
            #expect(error == .duplicateTodayTransfer)
        } catch {
            Issue.record("Unexpected error on identical replay: \(error)")
        }
        #expect(scaffold.entries().count == countAfterFirst)
        let replayBalances = scaffold.buckets.bucketBalances(profileRecordName: "hero1", familyRecordName: "fam1")
        #expect(replayBalances[.spend] == balancesAfterFirst[.spend])
        #expect(replayBalances[.shortTermSave] == balancesAfterFirst[.shortTermSave])
    }

    @Test
    func `divergent payload on the same base record extends deterministically`() async throws {
        let now = Date()
        let ms = Int(now.timeIntervalSince1970 * 1000)
        let cents = Int((abs(4.00) * 100).rounded())
        let baseRecordName = DeterministicRecordID.transfer(
            profileRecordName: "hero1",
            transferID: "\(ms)-\(cents)-\(BucketKind.spend.rawValue)-\(BucketKind.shortTermSave.rawValue)"
        )

        let scaffold = try TransferScaffold()
        scaffold.seed("l-spend-in", amount: 20.00, source: "quest", bucketKind: BucketKind.spend.rawValue)
        // WHY forced collision: squat on the base name with a different amount so
        // the real transfer meets a divergent payload at the same record.
        scaffold.seed(
            baseRecordName,
            amount: 1.00,
            source: "transfer",
            bucketKind: BucketKind.shortTermSave.rawValue,
            fromBucket: BucketKind.spend.rawValue,
            toBucket: BucketKind.shortTermSave.rawValue
        )

        let extended = try await scaffold.buckets.transfer(
            from: .spend, to: .shortTermSave, amount: 4.00,
            profile: scaffold.hero, family: scaffold.family,
            at: now
        )
        // WHY deterministic extension: a divergent collision keeps the base as a
        // prefix with a payload-derived suffix instead of forking randomly.
        #expect(extended.id.recordName != baseRecordName)
        #expect(extended.id.recordName.hasPrefix(baseRecordName))
        #expect(scaffold.entries().count == 3)
        let balances = scaffold.buckets.bucketBalances(profileRecordName: "hero1", familyRecordName: "fam1")
        #expect(balances[.spend] == 15.00)
        #expect(balances[.shortTermSave] == 5.00)

        // WHY cross-device convergence: the same divergent payload against the
        // same squatter must mint the same extended record on a fresh cache.
        let twin = try TransferScaffold()
        twin.seed("l-spend-in", amount: 20.00, source: "quest", bucketKind: BucketKind.spend.rawValue)
        twin.seed(
            baseRecordName,
            amount: 1.00,
            source: "transfer",
            bucketKind: BucketKind.shortTermSave.rawValue,
            fromBucket: BucketKind.spend.rawValue,
            toBucket: BucketKind.shortTermSave.rawValue
        )
        let twinExtended = try await twin.buckets.transfer(
            from: .spend, to: .shortTermSave, amount: 4.00,
            profile: twin.hero, family: twin.family,
            at: now
        )
        #expect(twinExtended.id.recordName == extended.id.recordName)
    }
}
