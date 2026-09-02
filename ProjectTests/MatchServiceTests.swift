//
//  MatchServiceTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct MatchServiceTests {
    // MARK: - Scaffold

    @MainActor
    struct Scaffold {
        let zoneID: CKRecordZone.ID
        let mock: MockCloudKitService
        let cache: CacheService
        let appState: AppState
        let match: MatchService
        let hero: Profile
        let guildMaster: Profile
        let family: Family
        let goal: Goal

        init(
            matchEnabled: Bool = true,
            matchRateBps: Int = 10000,
            matchMonthlyCapPennies: Int64? = nil
        ) throws {
            zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
            mock = MockCloudKitService()
            mock.activeFamilyZoneID = zoneID
            mock.activeIsOwner = true
            cache = try CacheService(inMemory: true)
            appState = AppState()
            appState.familyZoneID = zoneID
            appState.isZoneOwner = true
            match = MatchService(cloudKit: mock, cacheService: cache, appState: appState)

            let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
            let heroID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
            hero = Profile(
                displayName: "Hero",
                role: .hero,
                iCloudUserID: heroID,
                family: familyRef,
                matchEnabled: matchEnabled,
                matchRateBps: matchRateBps,
                matchMonthlyCapPennies: matchMonthlyCapPennies,
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
            goal = Goal(
                profile: CKRecord.Reference(recordID: heroID, action: .none),
                family: familyRef,
                bucketKind: .longTermSave,
                name: "Bike",
                targetAmountPennies: 50000,
                id: CKRecord.ID(recordName: "goal1", zoneID: zoneID)
            )
            mock.seedMockRecords([hero, guildMaster, family, goal])
            cache.context?.insert(ProfileCache(from: hero))
            cache.context?.insert(ProfileCache(from: guildMaster))
            cache.context?.insert(FamilyCache(from: family))
            cache.context?.insert(GoalCache(from: goal))
            _ = cache.saveContext()
            cache.markCacheFreshForTests(familyRecordName: family.id.recordName, type: .profile)
            cache.markCacheFreshForTests(familyRecordName: family.id.recordName, type: .family)
            cache.markCacheFreshForTests(familyRecordName: family.id.recordName, type: .ledgerEntry)
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
            cache.context?.insert(LedgerEntryCache(from: entry))
            _ = cache.saveContext()
        }

        func seedMatchEntry(amount: Double, date: Date, name: String) {
            seedLedger(amount: amount, bucket: .longTermSave, source: MatchService.ledgerSource, date: date, name: name)
        }

        func ledgerEntries() -> [LedgerEntryCache] {
            cache.fetchLedgerEntries(profileRecordName: hero.id.recordName, family: family.id.recordName)
        }

        func matchEntries() -> [LedgerEntryCache] {
            ledgerEntries().filter { $0.source == MatchService.ledgerSource }
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
        #expect(MatchService.monthKey(for: date) == "2026-08")
        #expect(MatchService.recordName(goalRecordName: "goal1", contributionEventID: "contrib-goal1-payout-period1") == "match-goal1-contrib-goal1-payout-period1")
    }

    // MARK: - Rounding down pennies

    @Test
    func `matchPennies rounds down`() {
        // 100% match on $3.33 → $3.33
        #expect(MatchService.matchPennies(contributionPennies: 333, rateBps: 10000) == 333)
        // 50% match on $5.00 → $2.50
        #expect(MatchService.matchPennies(contributionPennies: 500, rateBps: 5000) == 250)
        // 200% match on $10.00 → $20.00
        #expect(MatchService.matchPennies(contributionPennies: 1000, rateBps: 20000) == 2000)
        // Sub-penny rounds to zero
        #expect(MatchService.matchPennies(contributionPennies: 1, rateBps: 500) == 0)
        // Rate 0 → no match
        #expect(MatchService.matchPennies(contributionPennies: 1000, rateBps: 0) == 0)
    }

    // MARK: - Basic match

    @Test
    func `one hundred percent match on long term goal`() async throws {
        let sc = try Scaffold(matchRateBps: 10000)
        let date = sc.utcDate(year: 2026, month: 6)
        let entry = try await sc.match.applyMatch(
            for: sc.goal,
            contributionEventID: "contrib-goal1-payout-period1",
            contributionAmount: 5.00,
            date: date,
            heroProfile: sc.refreshHero(),
            family: sc.family
        )
        #expect(entry?.amount == 5.00)
        #expect(entry?.source == MatchService.ledgerSource)
        #expect(entry?.description == MatchService.entryDescription)
        #expect(entry?.bucketKind == BucketKind.longTermSave.rawValue)
        #expect(entry?.id.recordName == "match-goal1-contrib-goal1-payout-period1")
    }

    // MARK: - Idempotent double-run

    @Test
    func `double match on same contribution is idempotent`() async throws {
        let sc = try Scaffold()
        let date = sc.utcDate(year: 2026, month: 6)
        let contribID = "contrib-goal1-payout-period1"

        let first = try await sc.match.applyMatch(
            for: sc.goal,
            contributionEventID: contribID,
            contributionAmount: 10.00,
            date: date,
            heroProfile: sc.refreshHero(),
            family: sc.family
        )
        #expect(first != nil)
        #expect(first?.id.recordName == "match-goal1-contrib-goal1-payout-period1")

        let second = try await sc.match.applyMatch(
            for: sc.goal,
            contributionEventID: contribID,
            contributionAmount: 10.00,
            date: date,
            heroProfile: sc.refreshHero(),
            family: sc.family
        )
        #expect(second == nil)
        #expect(sc.matchEntries().count == 1)
    }

    // MARK: - Monthly cap enforcement

    @Test
    func `cap prevents exceeding monthly limit`() async throws {
        let sc = try Scaffold(matchRateBps: 10000, matchMonthlyCapPennies: 1000) // $10.00 cap
        let june = sc.utcDate(year: 2026, month: 6)

        // First contribution: $6.00 → $6.00 match (mtd=$6.00, remaining=$4.00)
        let e1 = try await sc.match.applyMatch(
            for: sc.goal,
            contributionEventID: "contrib-goal1-payout1",
            contributionAmount: 6.00,
            date: june,
            heroProfile: sc.refreshHero(),
            family: sc.family
        )
        #expect(e1?.amount == 6.00)

        // Second contribution: $8.00 → would be $8.00 match, but only $4.00 remaining
        let e2 = try await sc.match.applyMatch(
            for: sc.goal,
            contributionEventID: "contrib-goal1-payout2",
            contributionAmount: 8.00,
            date: june,
            heroProfile: sc.refreshHero(),
            family: sc.family
        )
        #expect(e2?.amount == 4.00)

        // Third contribution: capped because mtd already hit $10.00
        let e3 = try await sc.match.applyMatch(
            for: sc.goal,
            contributionEventID: "contrib-goal1-payout3",
            contributionAmount: 5.00,
            date: june,
            heroProfile: sc.refreshHero(),
            family: sc.family
        )
        #expect(e3 == nil)
        #expect(sc.matchEntries().count == 2)
    }

    @Test
    func `cap resets per month`() async throws {
        let sc = try Scaffold(matchRateBps: 10000, matchMonthlyCapPennies: 500) // $5.00 cap
        let june = sc.utcDate(year: 2026, month: 6, day: 15)
        let july = sc.utcDate(year: 2026, month: 7, day: 3)

        // June: max the cap
        let e1 = try await sc.match.applyMatch(
            for: sc.goal,
            contributionEventID: "contrib-goal1-june1",
            contributionAmount: 8.00,
            date: june,
            heroProfile: sc.refreshHero(),
            family: sc.family
        )
        #expect(e1?.amount == 5.00) // capped at $5.00

        // July: cap resets, full match again
        let e2 = try await sc.match.applyMatch(
            for: sc.goal,
            contributionEventID: "contrib-goal1-july1",
            contributionAmount: 6.00,
            date: july,
            heroProfile: sc.refreshHero(),
            family: sc.family
        )
        #expect(e2?.amount == 5.00) // capped at $5.00 in July too
        #expect(sc.matchEntries().count == 2)
    }

    @Test
    func `cap enforcement mid-month`() async throws {
        // Three contributions on the same day: the third should be fully
        // declined when the cap is already exhausted.
        let sc = try Scaffold(matchRateBps: 10000, matchMonthlyCapPennies: 300) // $3.00 cap
        let date = sc.utcDate(year: 2026, month: 8, day: 10)

        let e1 = try await sc.match.applyMatch(
            for: sc.goal,
            contributionEventID: "contrib-goal1-a",
            contributionAmount: 2.00,
            date: date,
            heroProfile: sc.refreshHero(),
            family: sc.family
        )
        #expect(e1?.amount == 2.00)

        let e2 = try await sc.match.applyMatch(
            for: sc.goal,
            contributionEventID: "contrib-goal1-b",
            contributionAmount: 2.00,
            date: date,
            heroProfile: sc.refreshHero(),
            family: sc.family
        )
        #expect(e2?.amount == 1.00) // only $1.00 remaining

        let e3 = try await sc.match.applyMatch(
            for: sc.goal,
            contributionEventID: "contrib-goal1-c",
            contributionAmount: 0.50,
            date: date,
            heroProfile: sc.refreshHero(),
            family: sc.family
        )
        #expect(e3 == nil) // cap exhausted

        #expect(sc.matchEntries().count == 2)
    }

    // MARK: - Rate > 100%

    @Test
    func `rate exceeding 100 percent`() async throws {
        // 200% match: $5.00 contribution → $10.00 from parent
        let sc = try Scaffold(matchRateBps: 20000)
        let date = sc.utcDate(year: 2026, month: 6)
        let entry = try await sc.match.applyMatch(
            for: sc.goal,
            contributionEventID: "contrib-goal1-highrate",
            contributionAmount: 5.00,
            date: date,
            heroProfile: sc.refreshHero(),
            family: sc.family
        )
        #expect(entry?.amount == 10.00)
    }

    @Test
    func `rate exceeding 100 percent still capped`() async throws {
        // 200% match with a $7.00 cap: $5.00 contribution → $10.00 match,
        // capped to $7.00.
        let sc = try Scaffold(matchRateBps: 20000, matchMonthlyCapPennies: 700)
        let date = sc.utcDate(year: 2026, month: 6)
        let entry = try await sc.match.applyMatch(
            for: sc.goal,
            contributionEventID: "contrib-goal1-highrate-cap",
            contributionAmount: 5.00,
            date: date,
            heroProfile: sc.refreshHero(),
            family: sc.family
        )
        #expect(entry?.amount == 7.00)
    }

    // MARK: - Multiple goals same month

    @Test
    func `multiple goals in same month share cap`() async throws {
        let sc = try Scaffold(matchRateBps: 10000, matchMonthlyCapPennies: 800) // $8.00 cap
        let june = sc.utcDate(year: 2026, month: 6)

        let goal2 = Goal(
            profile: CKRecord.Reference(recordID: sc.hero.id, action: .none),
            family: CKRecord.Reference(recordID: sc.family.id, action: .none),
            bucketKind: .longTermSave,
            name: "Scooter",
            targetAmountPennies: 30000,
            id: CKRecord.ID(recordName: "goal2", zoneID: sc.zoneID)
        )
        sc.mock.seedMockRecords([goal2])
        await sc.cache.upsertGoal(goal2)
        sc.cache.markCacheFreshForTests(familyRecordName: sc.family.id.recordName, type: .ledgerEntry)

        // Goal 1: $5.00 → $5.00 match (mtd = $5.00, remaining = $3.00)
        let e1 = try await sc.match.applyMatch(
            for: sc.goal,
            contributionEventID: "contrib-goal1-june1",
            contributionAmount: 5.00,
            date: june,
            heroProfile: sc.refreshHero(),
            family: sc.family
        )
        #expect(e1?.amount == 5.00)

        // Goal 2: $10.00 → would be $10.00, capped at $3.00 remaining
        let e2 = try await sc.match.applyMatch(
            for: goal2,
            contributionEventID: "contrib-goal2-june1",
            contributionAmount: 10.00,
            date: june,
            heroProfile: sc.refreshHero(),
            family: sc.family
        )
        #expect(e2?.amount == 3.00)
        #expect(sc.matchEntries().count == 2)
    }

    // MARK: - Non-long-term-save goal is no-op

    @Test
    func `non long-term-save goal is no-op`() async throws {
        let sc = try Scaffold()
        let spendGoal = Goal(
            profile: CKRecord.Reference(recordID: sc.hero.id, action: .none),
            family: CKRecord.Reference(recordID: sc.family.id, action: .none),
            bucketKind: .spend,
            name: "Candy",
            targetAmountPennies: 500,
            id: CKRecord.ID(recordName: "spendGoal", zoneID: sc.zoneID)
        )
        let result = try await sc.match.applyMatch(
            for: spendGoal,
            contributionEventID: "contrib-spendGoal-e1",
            contributionAmount: 5.00,
            date: sc.utcDate(year: 2026, month: 6),
            heroProfile: sc.refreshHero(),
            family: sc.family
        )
        #expect(result == nil)
        #expect(sc.matchEntries().isEmpty)
    }

    // MARK: - Disabled / missing config no-op

    @Test
    func `disabled match is no-op`() async throws {
        let sc = try Scaffold(matchEnabled: false)
        let result = try await sc.match.applyMatch(
            for: sc.goal,
            contributionEventID: "contrib-goal1-disabled",
            contributionAmount: 10.00,
            date: sc.utcDate(year: 2026, month: 6),
            heroProfile: sc.refreshHero(),
            family: sc.family
        )
        #expect(result == nil)
        #expect(sc.matchEntries().isEmpty)
    }

    @Test
    func `zero rate is no-op`() async throws {
        let sc = try Scaffold(matchRateBps: 0)
        let result = try await sc.match.applyMatch(
            for: sc.goal,
            contributionEventID: "contrib-goal1-zero-rate",
            contributionAmount: 10.00,
            date: sc.utcDate(year: 2026, month: 6),
            heroProfile: sc.refreshHero(),
            family: sc.family
        )
        #expect(result == nil)
    }

    @Test
    func `zero contribution is no-op`() async throws {
        let sc = try Scaffold()
        let result = try await sc.match.applyMatch(
            for: sc.goal,
            contributionEventID: "contrib-goal1-zero-amount",
            contributionAmount: 0.0,
            date: sc.utcDate(year: 2026, month: 6),
            heroProfile: sc.refreshHero(),
            family: sc.family
        )
        #expect(result == nil)
    }

    @Test
    func `sub-penny match is no-op`() async throws {
        // 1% match on $0.01 = 0.01p floor→0
        let sc = try Scaffold(matchRateBps: 100)
        let result = try await sc.match.applyMatch(
            for: sc.goal,
            contributionEventID: "contrib-goal1-tiny",
            contributionAmount: 0.01,
            date: sc.utcDate(year: 2026, month: 6),
            heroProfile: sc.refreshHero(),
            family: sc.family
        )
        #expect(result == nil)
    }

    // MARK: - Parent-only edit

    @Test
    func `hero cannot configure match`() async throws {
        let sc = try Scaffold()
        sc.appState.currentProfile = sc.hero
        await #expect(throws: FamilyServiceError.unauthorized) {
            _ = try await sc.match.updateMatchConfig(
                profile: sc.hero,
                enabled: true,
                rateBps: 5000,
                monthlyCapPennies: nil
            )
        }
    }

    @Test
    func `hero cannot apply match`() async throws {
        let sc = try Scaffold()
        sc.appState.currentProfile = sc.hero
        await #expect(throws: FamilyServiceError.unauthorized) {
            _ = try await sc.match.applyMatch(
                for: sc.goal,
                contributionEventID: "contrib-goal1-hero",
                contributionAmount: 5.00,
                date: sc.utcDate(year: 2026, month: 6),
                heroProfile: sc.hero,
                family: sc.family
            )
        }
    }

    @Test
    func `parent updates config and persists`() async throws {
        let sc = try Scaffold(matchEnabled: false, matchRateBps: 0)
        let updated = try await sc.match.updateMatchConfig(
            profile: sc.hero,
            enabled: true,
            rateBps: 15000, // 150%
            monthlyCapPennies: 2000 // $20.00
        )
        #expect(updated.matchEnabled == true)
        #expect(updated.matchRateBps == 15000)
        #expect(updated.matchMonthlyCapPennies == 2000)
        let cached = try #require(sc.cache.fetchProfile(recordName: sc.hero.id.recordName, family: sc.family.id.recordName))
        #expect(cached.matchEnabled == true)
        #expect(cached.matchRateBps == 15000)
    }
}
