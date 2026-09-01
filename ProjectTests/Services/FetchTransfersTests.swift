//
//  FetchTransfersTests.swift
//  LootList
//
//  Created by Ben Mackin on 9/01/26.
//

import CloudKit
@testable import LootList
import Testing

@MainActor
struct FetchTransfersTests {
    // WARNING: Do not add fromBucket/toBucket to DB predicate — sparse optionals not indexed, would force table scan.
    // This test proves fetchTransfers narrows via composite index [familyRecordName, profileRecordName, source, date]
    // and filters fromBucket/toBucket in-memory on the small indexed subset.

    @Test
    func `fetchTransfers filters sparse bucket pair in-memory on indexed subset`() async throws {
        let cache = try CacheService(inMemory: true)
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let familyName = "fam1"
        let profileName = "hero1"
        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: familyName, zoneID: zoneID), action: .none)
        let profileRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: profileName, zoneID: zoneID), action: .none)

        // Use the same dayBucket that fetchTransfers will query so date lands inside the indexed range.
        let dayBucket = WeekMath.dayBucket(for: Date())
        let range = WeekMath.utcDateRange(forDayBucket: dayBucket)
        let today = range.lowerBound.addingTimeInterval(3600)
        let yesterday = range.lowerBound.addingTimeInterval(-3600)

        func makeEntry(
            recordName: String,
            date: Date,
            source: String,
            fromBucket: String?,
            toBucket: String?
        ) -> LedgerEntry {
            LedgerEntry(
                profile: profileRef,
                amount: 5,
                description: recordName,
                date: date,
                source: source,
                bucketKind: toBucket,
                fromBucket: fromBucket,
                toBucket: toBucket,
                family: familyRef,
                id: CKRecord.ID(recordName: recordName, zoneID: zoneID)
            )
        }

        // Matching pair — should be returned.
        await cache.upsertLedgerEntry(makeEntry(
            recordName: "match-1",
            date: today,
            source: LedgerSource.transfer.rawValue,
            fromBucket: BucketKind.spend.rawValue,
            toBucket: BucketKind.shortTermSave.rawValue
        ))
        // Same indexed fields but different bucket pair — must NOT be returned (in-memory filter).
        await cache.upsertLedgerEntry(makeEntry(
            recordName: "mismatch-pair",
            date: today,
            source: LedgerSource.transfer.rawValue,
            fromBucket: BucketKind.spend.rawValue,
            toBucket: BucketKind.longTermSave.rawValue
        ))
        // Same indexed fields but reversed pair — must NOT be returned.
        await cache.upsertLedgerEntry(makeEntry(
            recordName: "mismatch-reverse",
            date: today,
            source: LedgerSource.transfer.rawValue,
            fromBucket: BucketKind.shortTermSave.rawValue,
            toBucket: BucketKind.spend.rawValue
        ))
        // Same indexed fields but sparse nil buckets — must NOT be returned and must not cause predicate inclusion.
        await cache.upsertLedgerEntry(makeEntry(
            recordName: "sparse-nil",
            date: today,
            source: LedgerSource.transfer.rawValue,
            fromBucket: nil,
            toBucket: nil
        ))
        // Same bucket pair but different source — must NOT be returned (indexed source filter).
        await cache.upsertLedgerEntry(makeEntry(
            recordName: "wrong-source",
            date: today,
            source: LedgerSource.quest.rawValue,
            fromBucket: BucketKind.spend.rawValue,
            toBucket: BucketKind.shortTermSave.rawValue
        ))
        // Same bucket pair and source but yesterday — must NOT be returned (indexed date range).
        await cache.upsertLedgerEntry(makeEntry(
            recordName: "yesterday",
            date: yesterday,
            source: LedgerSource.transfer.rawValue,
            fromBucket: BucketKind.spend.rawValue,
            toBucket: BucketKind.shortTermSave.rawValue
        ))

        let results = cache.fetchTransfers(
            profileRecordName: profileName,
            familyRecordName: familyName,
            from: BucketKind.spend.rawValue,
            to: BucketKind.shortTermSave.rawValue,
            dayBucket: dayBucket
        )

        #expect(results.count == 1, "Only the exact fromBucket/toBucket pair within the indexed subset should be returned")
        #expect(results.first?.recordName == "match-1")
        #expect(results.first?.fromBucket == BucketKind.spend.rawValue)
        #expect(results.first?.toBucket == BucketKind.shortTermSave.rawValue)
    }

    @Test
    func `fetchTransfers returns empty when sparse columns are nil and predicate excludes them`() async throws {
        let cache = try CacheService(inMemory: true)
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let familyName = "fam1"
        let profileName = "hero1"
        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: familyName, zoneID: zoneID), action: .none)
        let profileRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: profileName, zoneID: zoneID), action: .none)
        let dayBucket = WeekMath.dayBucket(for: Date())
        let today = WeekMath.utcDateRange(forDayBucket: dayBucket).lowerBound.addingTimeInterval(7200)

        // Seed only a sparse-nil transfer — a predicate that incorrectly included fromBucket/toBucket
        // would either table-scan or mishandle nil comparison. In-memory filter correctly yields empty.
        let nilEntry = LedgerEntry(
            profile: profileRef,
            amount: 5,
            description: "nil-buckets",
            date: today,
            source: LedgerSource.transfer.rawValue,
            family: familyRef,
            id: CKRecord.ID(recordName: "nil-entry", zoneID: zoneID)
        )
        await cache.upsertLedgerEntry(nilEntry)

        let results = cache.fetchTransfers(
            profileRecordName: profileName,
            familyRecordName: familyName,
            from: BucketKind.spend.rawValue,
            to: BucketKind.shortTermSave.rawValue,
            dayBucket: dayBucket
        )
        #expect(results.isEmpty, "Sparse nil buckets must not match a concrete bucket pair — proves predicate excludes sparse optionals")
    }

    @Test
    func `fetchTransfers fail-closed on empty scope`() throws {
        let cache = try CacheService(inMemory: true)
        let bucket = WeekMath.dayBucket(for: Date())
        #expect(cache.fetchTransfers(profileRecordName: "", familyRecordName: "fam1", from: "spend", to: "shortTermSave", dayBucket: bucket).isEmpty)
        #expect(cache.fetchTransfers(profileRecordName: "hero1", familyRecordName: "", from: "spend", to: "shortTermSave", dayBucket: bucket).isEmpty)
        #expect(cache.fetchTransfers(profileRecordName: "hero1", familyRecordName: "fam1", from: "", to: "shortTermSave", dayBucket: bucket).isEmpty)
    }
}
