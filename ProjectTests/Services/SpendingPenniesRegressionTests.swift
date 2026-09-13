//
//  SpendingPenniesRegressionTests.swift
//  LootList
//
//  Created by Ben Mackin on 9/12/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

/// WHY penny canon: text entry, display, and ledger writes share one integer path.
@MainActor
struct SpendingPenniesRegressionTests {
    private func makeZoneID() -> CKRecordZone.ID {
        ExhaustiveCacheFixtures.sharedZoneID
    }

    private func setupActiveScope(
        appState: AppState,
        cloudKit: MockCloudKitService,
        family: Family,
        actingProfile: Profile
    ) {
        appState.family = family
        appState.familyZoneID = family.id.zoneID
        appState.isZoneOwner = true
        cloudKit.activeFamilyZoneID = family.id.zoneID
        cloudKit.activeIsOwner = true
        appState.currentProfile = actingProfile
    }

    @Test
    func `shared parser maps 12_75 to 1275 pennies`() {
        // WHY canonical proof: CurrencyFormatterPenniesTests owns the 12.75==1275 assertion.
        #expect(LedgerCSVParser.parseAmount("12.75") == 1275)
    }

    @Test
    func `editing string round-trips 1275 pennies`() {
        let edited = CurrencyFormatter.editingString(pennies: 1275)
        #expect(CurrencyFormatter.pennies(from: edited) == 1275)
        // WHY locale-proof: digits survive any currency symbol or separator placement.
        #expect(CurrencyFormatter.string(pennies: 1275).filter(\.isWholeNumber) == "1275")
    }

    @Test
    func `logManual mints negative spend entry for 1275`() async throws {
        let zoneID = makeZoneID()
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = SpendingService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let hero = ExhaustiveCacheFixtures.sharedHero(zoneID: zoneID, displayName: "Child Hero", iCloudRecordName: "hero1")
        let family = ExhaustiveCacheFixtures.sharedFamily(zoneID: zoneID, creatorUserRecordName: "parent1")
        setupActiveScope(appState: appState, cloudKit: cloudKit, family: family, actingProfile: hero)

        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = try await service.logManual(
            profile: hero,
            family: family,
            familyRecordName: family.id.recordName,
            description: "Penny flow",
            amount: 1275,
            date: fixedDate
        )

        #expect(entry.amount == -1275)
        #expect(entry.source == LedgerSource.manual.rawValue)
        #expect(entry.bucketKind == BucketKind.spend.rawValue)
        // WHY deterministic shape: source-profile-family-ms-cents-hash lets CloudKit dedupe.
        #expect(entry.id.recordName.hasPrefix("manual-hero1-fam1-1700000000000-1275-"))
        #expect(!entry.id.recordName.lowercased().contains("uuid"))

        let cached = cache.fetchLedgerEntries(profileRecordName: hero.id.recordName, family: family.id.recordName)
        #expect(cached.count == 1)
        #expect(cached.first?.amount == -1275)
        #expect(cached.first?.bucketKind == BucketKind.spend.rawValue)
    }

    @Test
    func `logManual preserves deterministic IDs and validation boundaries`() async throws {
        let zoneID = makeZoneID()
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = SpendingService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let hero = ExhaustiveCacheFixtures.sharedHero(zoneID: zoneID, displayName: "Child Hero", iCloudRecordName: "hero1")
        let family = ExhaustiveCacheFixtures.sharedFamily(zoneID: zoneID, creatorUserRecordName: "parent1")
        setupActiveScope(appState: appState, cloudKit: cloudKit, family: family, actingProfile: hero)

        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try await service.logManual(
            profile: hero,
            family: family,
            familyRecordName: family.id.recordName,
            description: "Penny flow",
            amount: 1275,
            date: fixedDate
        )
        let second = try await service.logManual(
            profile: hero,
            family: family,
            familyRecordName: family.id.recordName,
            description: "Penny flow",
            amount: 1275,
            date: fixedDate
        )
        // WHY idempotent: same payload converges instead of duplicating rows.
        #expect(first.id.recordName == second.id.recordName)
        #expect(cache.fetchLedgerEntries(profileRecordName: hero.id.recordName, family: family.id.recordName).count == 1)

        // WHY boundary: non-positive amounts never mint ledger rows.
        await #expect(throws: SpendingServiceError.self) {
            _ = try await service.logManual(
                profile: hero,
                family: family,
                familyRecordName: family.id.recordName,
                description: "Penny flow",
                amount: 0,
                date: fixedDate
            )
        }
        // WHY boundary: blank descriptions never mint ledger rows.
        await #expect(throws: SpendingServiceError.self) {
            _ = try await service.logManual(
                profile: hero,
                family: family,
                familyRecordName: family.id.recordName,
                description: "   ",
                amount: 1275,
                date: fixedDate
            )
        }
    }
}
