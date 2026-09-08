//
//  LedgerTransferParityTests.swift
//  LootList
//
//  Created by Ben Mackin on 9/07/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct LedgerTransferParityTests {
    private let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")

    private func ref(_ name: String) -> CKRecord.Reference {
        CKRecord.Reference(recordID: CKRecord.ID(recordName: name, zoneID: zoneID), action: .none)
    }

    private func id(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    private func transferEntry(
        recordName: String = "transfer-hero1-1750000000000-400-spend-shortTermSave",
        from: BucketKind = .spend,
        to: BucketKind = .shortTermSave
    ) -> LedgerEntry {
        LedgerEntry(
            profile: ref("hero1"),
            amount: 400,
            description: "Transfer from \(from.displayName) to \(to.displayName)",
            location: "App",
            date: Date(timeIntervalSince1970: 1_750_000_000),
            source: LedgerSource.transfer.rawValue,
            bucketKind: to.rawValue,
            fromBucket: from.rawValue,
            toBucket: to.rawValue,
            family: ref("fam1"),
            id: id(recordName)
        )
    }

    @Test
    func `transfer triple round-trips through CKRecord`() throws {
        let entry = transferEntry()
        let decoded = try LedgerEntry(record: entry.toRecord())
        #expect(decoded.bucketKind == BucketKind.shortTermSave.rawValue)
        #expect(decoded.fromBucket == BucketKind.spend.rawValue)
        #expect(decoded.toBucket == BucketKind.shortTermSave.rawValue)
        #expect(decoded.amount == entry.amount)
        #expect(decoded.source == LedgerSource.transfer.rawValue)
        #expect(decoded.id.recordName == entry.id.recordName)
    }

    @Test
    func `transfer triple round-trips through cache conversion`() {
        let entry = transferEntry()
        let cache = LedgerEntryCache(from: entry)
        #expect(cache.bucketKind == BucketKind.shortTermSave.rawValue)
        #expect(cache.fromBucket == BucketKind.spend.rawValue)
        #expect(cache.toBucket == BucketKind.shortTermSave.rawValue)
        let restored = cache.toLedgerEntry(zoneID: zoneID)
        #expect(restored.bucketKind == entry.bucketKind)
        #expect(restored.fromBucket == entry.fromBucket)
        #expect(restored.toBucket == entry.toBucket)
        #expect(restored == entry)
    }

    @Test
    func `managedFieldKeys includes all three bucket keys`() {
        #expect(LedgerEntry.managedFieldKeys.contains("bucketKind"))
        #expect(LedgerEntry.managedFieldKeys.contains("fromBucket"))
        #expect(LedgerEntry.managedFieldKeys.contains("toBucket"))
        let actual = Set(transferEntry().toRecord().allKeys())
        #expect(actual == LedgerEntry.managedFieldKeys)
    }

    @Test
    func `recordBridge preserves transfer triple with family parent`() async throws {
        let cache = try CacheService(inMemory: true)
        let entry = transferEntry(recordName: "led-bridge-transfer")
        await cache.upsertLedgerEntry(entry)
        let identity = ScopedRecordIdentity(
            databaseScope: .private,
            zoneID: zoneID,
            recordID: entry.id,
            familyRecordName: "fam1"
        )
        let bridged = try #require(RecordBridge.record(for: identity, cacheService: cache))
        #expect((bridged["bucketKind"] as? String) == BucketKind.shortTermSave.rawValue)
        #expect((bridged["fromBucket"] as? String) == BucketKind.spend.rawValue)
        #expect((bridged["toBucket"] as? String) == BucketKind.shortTermSave.rawValue)
        #expect(bridged.parent?.recordID.recordName == "fam1")
        #expect(bridged.parent?.recordID.zoneID == zoneID)
        let decoded = try LedgerEntry(record: bridged)
        #expect(decoded.fromBucket == entry.fromBucket)
        #expect(decoded.toBucket == entry.toBucket)
        #expect(decoded.bucketKind == entry.bucketKind)
    }

    @Test
    func `transfer recordName stays within CloudKit limits`() {
        // WHY 255: CloudKit rejects record names beyond this length.
        let limit = 255
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let ms = Int(now.timeIntervalSince1970 * 1000)
        let transferID = "\(ms)-99999999-\(BucketKind.shortTermSave.rawValue)-\(BucketKind.longTermSave.rawValue)"
        let worstProfile = String(repeating: "a", count: 64)
        let worst = DeterministicRecordID.transfer(profileRecordName: worstProfile, transferID: transferID)
        #expect(worst.count <= limit)
        #expect(worst.hasPrefix("transfer-\(worstProfile)-"))
        let extended = "\(worst)-abcd1234-999"
        #expect(extended.count <= limit)
        let uuidProfile = UUID().uuidString
        let real = DeterministicRecordID.transfer(profileRecordName: uuidProfile, transferID: transferID)
        #expect(real.count <= limit)
    }

    @Test
    func `transfer IDs are deterministic without random fallback`() {
        let first = DeterministicRecordID.transfer(profileRecordName: "hero1", transferID: "1750000000000-400-spend-shortTermSave")
        let second = DeterministicRecordID.transfer(profileRecordName: "hero1", transferID: "1750000000000-400-spend-shortTermSave")
        #expect(first == second)
        let other = DeterministicRecordID.transfer(profileRecordName: "hero1", transferID: "1750000001000-400-spend-shortTermSave")
        #expect(other != first)
        #expect(first == "transfer-hero1-1750000000000-400-spend-shortTermSave")
    }

    @Test
    func `bucketService transfer synthesis never drops from-to`() async throws {
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let hero = Profile(
            displayName: "Hero",
            role: .hero,
            iCloudUserID: id("u1"),
            family: ref("fam1"),
            id: id("hero1")
        )
        let family = Family(name: "Fam", creatorUserRecordName: "u1", id: id("fam1"))
        appState.currentProfile = hero
        appState.family = family
        appState.familyZoneID = zoneID
        await cache.upsertLedgerEntry(LedgerEntry(
            profile: ref("hero1"),
            amount: 2000,
            description: "seed",
            source: LedgerSource.quest.rawValue,
            bucketKind: BucketKind.spend.rawValue,
            family: ref("fam1"),
            id: id("seed-spend")
        ))
        let buckets = BucketService(cacheService: cache, syncCoordinator: NoopSyncEnqueuing(), appState: appState)
        let entry = try await buckets.transfer(
            from: .spend,
            to: .shortTermSave,
            amount: 400,
            profile: hero,
            family: family,
            at: Date(timeIntervalSince1970: 1_750_000_000)
        )
        #expect(entry.fromBucket == BucketKind.spend.rawValue)
        #expect(entry.toBucket == BucketKind.shortTermSave.rawValue)
        #expect(entry.bucketKind == BucketKind.shortTermSave.rawValue)
        let decoded = try LedgerEntry(record: entry.toRecord())
        #expect(decoded.fromBucket == entry.fromBucket)
        #expect(decoded.toBucket == entry.toBucket)
    }
}
