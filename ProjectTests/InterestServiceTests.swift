//
//  InterestServiceTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct InterestServiceTests {
    // MARK: - Scaffold

    @MainActor
    struct Scaffold {
        let zoneID: CKRecordZone.ID
        let mock: MockCloudKitService
        let cache: CacheService
        let appState: AppState
        let interest: InterestService
        let hero: Profile
        let guildMaster: Profile
        let family: Family

        init(
            interestBucket: BucketKind? = .longTermSave,
            interestRateBps: Int = 500,
            interestIsCompound: Bool = false,
            interestEnabled: Bool = true
        ) throws {
            zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
            mock = MockCloudKitService()
            mock.activeFamilyZoneID = zoneID
            mock.activeIsOwner = true
            cache = try CacheService(inMemory: true)
            appState = AppState()
            appState.familyZoneID = zoneID
            appState.isZoneOwner = true
            interest = InterestService(cloudKit: mock, cacheService: cache, appState: appState)

            let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
            let heroID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
            hero = Profile(
                displayName: "Hero",
                role: .hero,
                iCloudUserID: heroID,
                family: familyRef,
                interestEnabled: interestEnabled,
                interestBucket: interestBucket?.rawValue,
                interestRateBps: interestRateBps,
                interestIsCompound: interestIsCompound,
                id: heroID
            )
            let gmID = CKRecord.ID(recordName: "gm1", zoneID: zoneID)
            guildMaster = Profile(
                displayName: "Guild Master",
                role: .guildMaster,
                iCloudUserID: gmID,
                family: familyRef,
                id: gmID
            )
            family = Family(
                name: "Test Guild",
                createdBy: gmID,
                payoutDay: .sunday,
                id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
            )
            mock.seedMockRecords([hero, guildMaster, family])
            cache.upsertProfile(hero)
            cache.upsertProfile(guildMaster)
            cache.upsertFamily(family)
            cache.markCacheFresh(familyRecordName: family.id.recordName, type: .profile)
            cache.markCacheFresh(familyRecordName: family.id.recordName, type: .family)
            cache.markCacheFresh(familyRecordName: family.id.recordName, type: .ledgerEntry)
            appState.currentProfile = guildMaster
            appState.family = family
        }

        func utcDate(year: Int, month: Int, day: Int = 15) -> Date {
            var comps = DateComponents()
            comps.year = year
            comps.month = month
            comps.day = day
            comps.hour = 12
            return Calendar.iso8601UTC.date(from: comps) ?? Date()
        }

        func seedLedger(amount: Double, bucket: BucketKind, source: String = "quest", date: Date = Date(), name: String) {
            let entry = LedgerEntry(
                profile: CKRecord.Reference(recordID: hero.id, action: .none),
                amount: amount,
                description: name,
                date: date,
                source: source,
                bucketKind: bucket.rawValue,
                family: CKRecord.Reference(recordID: family.id, action: .none),
                id: CKRecord.ID(recordName: name, zoneID: zoneID)
            )
            cache.upsertLedgerEntry(entry)
        }

        func ledgerEntries() -> [LedgerEntryCache] {
            cache.fetchLedgerEntries(profileRecordName: hero.id.recordName, family: family.id.recordName)
        }

        func interestEntries() -> [LedgerEntryCache] {
            ledgerEntries().filter { $0.source == InterestService.ledgerSource }
        }

        func refreshHero() throws -> Profile {
            let cached = try #require(cache.fetchProfile(recordName: hero.id.recordName, family: family.id.recordName))
            return cached.toProfile(zoneID: zoneID)
        }
    }

    // MARK: - Deterministic ID

    @Test
    func `monthKey uses UTC calendar`() throws {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 8
        comps.day = 1
        let date = try #require(Calendar.iso8601UTC.date(from: comps))
        #expect(InterestService.monthKey(for: date) == "2026-08")
        #expect(InterestService.recordName(profileRecordName: "hero1", monthKey: "2026-08") == "interest-hero1-2026-08")
    }

    // MARK: - Rounding down pennies

    @Test
    func `interestPennies rounds down`() {
        // 333 cents at 3.33% (333 bps) would be 11.0889 but floor is 11
        #expect(InterestService.interestPennies(basePennies: 333, rateBps: 333) == 11)
        #expect(InterestService.interestPennies(basePennies: 1000, rateBps: 333) == 33)
        // 10.00 (1000p) at 5% = 50 exactly
        #expect(InterestService.interestPennies(basePennies: 1000, rateBps: 500) == 50)
        // Sub-penny rounds to zero
        #expect(InterestService.interestPennies(basePennies: 1, rateBps: 500) == 0)
    }

    @Test
    func `apply rounds down sub-penny remainder`() async throws {
        let sc = try Scaffold(interestRateBps: 333, interestIsCompound: false)
        // Balance 1000p at 3.33% → 33p = $0.33 after floor
        sc.seedLedger(amount: 10.0, bucket: .longTermSave, name: "seed")
        let profile = try sc.refreshHero()
        let entry = try await sc.interest.applyMonthlyInterest(profile: profile, family: sc.family, date: sc.utcDate(year: 2026, month: 7))
        #expect(entry?.amount == 0.33)
        #expect(entry?.source == "interest")
        #expect(entry?.description == "Parent Interest")
        #expect(entry?.bucketKind == BucketKind.longTermSave.rawValue)
    }

    // MARK: - Idempotent double-run

    @Test
    func `double apply in same month is idempotent`() async throws {
        let sc = try Scaffold()
        sc.seedLedger(amount: 20.0, bucket: .longTermSave, name: "seed")
        let date = sc.utcDate(year: 2026, month: 6)
        let hero1 = try sc.refreshHero()
        let first = try await sc.interest.applyMonthlyInterest(profile: hero1, family: sc.family, date: date)
        #expect(first != nil)
        #expect(first?.id.recordName == "interest-hero1-2026-06")
        let hero2 = try sc.refreshHero()
        let second = try await sc.interest.applyMonthlyInterest(profile: hero2, family: sc.family, date: date)
        #expect(second == nil)
        #expect(sc.interestEntries().count == 1)
    }

    // MARK: - Compound accumulation

    @Test
    func `compound accumulates across months`() async throws {
        // 10.00 at 10% (1000 bps) compound: month1 100p → 11.00, month2 110p → 12.10, month3 121p → 13.31
        let sc = try Scaffold(interestRateBps: 1000, interestIsCompound: true)
        sc.seedLedger(amount: 10.0, bucket: .longTermSave, name: "seed")

        var hero = try sc.refreshHero()
        let m1 = sc.utcDate(year: 2026, month: 6)
        let e1 = try await sc.interest.applyMonthlyInterest(profile: hero, family: sc.family, date: m1)
        #expect(e1?.amount == 1.0)
        hero = try sc.refreshHero()

        let m2 = sc.utcDate(year: 2026, month: 7)
        let e2 = try await sc.interest.applyMonthlyInterest(profile: hero, family: sc.family, date: m2)
        // 1100p * 10% = 110p = 1.10 (compound includes prior interest)
        #expect(e2?.amount == 1.1)

        hero = try sc.refreshHero()
        let m3 = sc.utcDate(year: 2026, month: 8)
        let e3 = try await sc.interest.applyMonthlyInterest(profile: hero, family: sc.family, date: m3)
        // 1210p * 10% = 121p = 1.21
        #expect(e3?.amount == 1.21)

        #expect(sc.interestEntries().count == 3)
        // Verify deterministic names differ by month
        #expect(e1?.id.recordName == "interest-hero1-2026-06")
        #expect(e2?.id.recordName == "interest-hero1-2026-07")
        #expect(e3?.id.recordName == "interest-hero1-2026-08")
    }

    @Test
    func `simple does not compound`() async throws {
        let sc = try Scaffold(interestRateBps: 1000, interestIsCompound: false)
        sc.seedLedger(amount: 10.0, bucket: .longTermSave, name: "seed")

        var hero = try sc.refreshHero()
        let m1 = sc.utcDate(year: 2026, month: 6)
        let e1 = try await sc.interest.applyMonthlyInterest(profile: hero, family: sc.family, date: m1)
        #expect(e1?.amount == 1.0)
        hero = try sc.refreshHero()

        let m2 = sc.utcDate(year: 2026, month: 7)
        let e2 = try await sc.interest.applyMonthlyInterest(profile: hero, family: sc.family, date: m2)
        // Simple ignores prior interest: still 1000p *10% = 1.00
        #expect(e2?.amount == 1.0)

        hero = try sc.refreshHero()
        let m3 = sc.utcDate(year: 2026, month: 8)
        let e3 = try await sc.interest.applyMonthlyInterest(profile: hero, family: sc.family, date: m3)
        #expect(e3?.amount == 1.0)
        #expect(sc.interestEntries().count == 3)
    }

    // MARK: - Projection helper

    @Test
    func `projection matches engine over three months`() {
        // Starting 1000p at 5% simple: 50, 50, 50
        #expect(InterestService.projectionPennies(startingPennies: 1000, rateBps: 500, isCompound: false, months: 3) == [50, 50, 50])
        // Compound: 50, 52 (1050*5%=52.5 floor 52), 55 (1102*5%=55.1 floor 55)
        #expect(InterestService.projectionPennies(startingPennies: 1000, rateBps: 500, isCompound: true, months: 3) == [50, 52, 55])
    }

    // MARK: - Disabled / missing config no-op

    @Test
    func `disabled config is no-op`() async throws {
        let sc = try Scaffold(interestEnabled: false)
        sc.seedLedger(amount: 20.0, bucket: .longTermSave, name: "seed")
        let hero = try sc.refreshHero()
        let result = try await sc.interest.applyMonthlyInterest(profile: hero, family: sc.family, date: sc.utcDate(year: 2026, month: 6))
        #expect(result == nil)
        #expect(sc.interestEntries().isEmpty)
    }

    @Test
    func `zero balance is no-op`() async throws {
        let sc = try Scaffold()
        let hero = try sc.refreshHero()
        let result = try await sc.interest.applyMonthlyInterest(profile: hero, family: sc.family, date: sc.utcDate(year: 2026, month: 6))
        #expect(result == nil)
    }

    @Test
    func `sub-penny balance is no-op`() async throws {
        // 1 cent at 5% = 0.05 cents → floor 0
        let sc = try Scaffold(interestRateBps: 500)
        sc.seedLedger(amount: 0.01, bucket: .longTermSave, name: "tiny")
        let hero = try sc.refreshHero()
        let result = try await sc.interest.applyMonthlyInterest(profile: hero, family: sc.family, date: sc.utcDate(year: 2026, month: 6))
        #expect(result == nil)
    }

    // MARK: - Parent-only edit

    @Test
    func `hero cannot configure interest`() async throws {
        let sc = try Scaffold()
        sc.appState.currentProfile = sc.hero
        await #expect(throws: FamilyServiceError.unauthorized) {
            _ = try await sc.interest.updateInterestConfig(profile: sc.hero, enabled: true, bucket: .shortTermSave, rateBps: 500, isCompound: false)
        }
    }

    @Test
    func `hero cannot apply interest`() async throws {
        let sc = try Scaffold()
        sc.seedLedger(amount: 20.0, bucket: .longTermSave, name: "seed")
        sc.appState.currentProfile = sc.hero
        await #expect(throws: FamilyServiceError.unauthorized) {
            _ = try await sc.interest.applyMonthlyInterest(profile: sc.hero, family: sc.family, date: sc.utcDate(year: 2026, month: 6))
        }
    }

    @Test
    func `parent updates config and persists`() async throws {
        let sc = try Scaffold(interestRateBps: 0, interestEnabled: false)
        let updated = try await sc.interest.updateInterestConfig(profile: sc.hero, enabled: true, bucket: .shortTermSave, rateBps: 250, isCompound: true)
        #expect(updated.interestEnabled == true)
        #expect(updated.interestBucket == BucketKind.shortTermSave.rawValue)
        #expect(updated.interestRateBps == 250)
        #expect(updated.interestIsCompound == true)
        guard let cached = sc.cache.fetchProfile(recordName: sc.hero.id.recordName, family: sc.family.id.recordName) else {
            Issue.record("Expected cached profile after interest config update")
            return
        }
        #expect(cached.interestEnabled == true)
        #expect(cached.interestRateBps == 250)
    }
}
