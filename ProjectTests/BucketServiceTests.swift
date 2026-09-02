//
//  BucketServiceTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct BucketServiceTests {
    // MARK: - Split Math

    @Test
    func `split allocates every penny exactly`() {
        let shares = BucketService.splitPennies(2500,
                                                spendPercent: 60,
                                                shortPercent: 25,
                                                longPercent: 15)
        #expect(shares.first(where: { $0.kind == .spend })?.pennies == 1500)
        #expect(shares.first(where: { $0.kind == .shortTermSave })?.pennies == 625)
        #expect(shares.first(where: { $0.kind == .longTermSave })?.pennies == 375)
        #expect(shares.reduce(0) { $0 + $1.pennies } == 2500)
    }

    @Test
    func `leftover pennies go to largest remainders in deterministic order`() {
        // 10 pennies at equal thirds leaves one penny: the tie resolves to
        // spend so the same input never produces two different allocations.
        let shares = BucketService.splitPennies(10,
                                                spendPercent: 1,
                                                shortPercent: 1,
                                                longPercent: 1)
        #expect(shares.first(where: { $0.kind == .spend })?.pennies == 4)
        #expect(shares.first(where: { $0.kind == .shortTermSave })?.pennies == 3)
        #expect(shares.first(where: { $0.kind == .longTermSave })?.pennies == 3)
        #expect(shares.reduce(0) { $0 + $1.pennies } == 10)
    }

    @Test
    func `zero percentage bucket receives nothing but others stay exact`() {
        let shares = BucketService.splitPennies(100,
                                                spendPercent: 50,
                                                shortPercent: 50,
                                                longPercent: 0)
        #expect(shares.first(where: { $0.kind == .spend })?.pennies == 50)
        #expect(shares.first(where: { $0.kind == .shortTermSave })?.pennies == 50)
        #expect(shares.first(where: { $0.kind == .longTermSave })?.pennies == 0)
        #expect(shares.reduce(0) { $0 + $1.pennies } == 100)
    }

    @Test
    func `hundred percent single bucket takes everything`() {
        let shares = BucketService.splitPennies(12345,
                                                spendPercent: 0,
                                                shortPercent: 100,
                                                longPercent: 0)
        #expect(shares.first(where: { $0.kind == .spend })?.pennies == 0)
        #expect(shares.first(where: { $0.kind == .shortTermSave })?.pennies == 12345)
        #expect(shares.first(where: { $0.kind == .longTermSave })?.pennies == 0)
        #expect(shares.reduce(0) { $0 + $1.pennies } == 12345)
    }

    @Test
    func `all zero percentages fail safe to spend`() {
        let shares = BucketService.splitPennies(500,
                                                spendPercent: 0,
                                                shortPercent: 0,
                                                longPercent: 0)
        #expect(shares.count == 1)
        #expect(shares.first?.kind == .spend)
        #expect(shares.first?.pennies == 500)
    }

    @Test
    func `percentages not summing to 100 still conserve the total`() {
        let shares = BucketService.splitPennies(101,
                                                spendPercent: 55,
                                                shortPercent: 55,
                                                longPercent: 55)
        #expect(shares.reduce(0) { $0 + $1.pennies } == 101)

        let scaled = BucketService.splitPennies(1100,
                                                spendPercent: 70,
                                                shortPercent: 20,
                                                longPercent: 20)
        #expect(scaled.reduce(0) { $0 + $1.pennies } == 1100)
    }

    /// A spend/short/long percentage triple for the conservation sweep.
    private struct SplitConfig: CustomStringConvertible {
        let spend: Int
        let short: Int
        let long: Int

        var description: String {
            "spend \(spend)/short \(short)/long \(long)"
        }
    }

    @Test
    func `sweep of configurations always sums to the total`() {
        let totals = [0, 1, 7, 99, 100, 250, 2500, 123_456]
        let configs: [SplitConfig] = [
            SplitConfig(spend: 100, short: 0, long: 0),
            SplitConfig(spend: 0, short: 100, long: 0),
            SplitConfig(spend: 0, short: 0, long: 100),
            SplitConfig(spend: 60, short: 25, long: 15),
            SplitConfig(spend: 33, short: 33, long: 34),
            SplitConfig(spend: 1, short: 1, long: 1),
            SplitConfig(spend: 50, short: 50, long: 0),
            SplitConfig(spend: 40, short: 40, long: 20),
            SplitConfig(spend: 10, short: 80, long: 10),
            SplitConfig(spend: 0, short: 37, long: 63),
            SplitConfig(spend: 29, short: 29, long: 42)
        ]
        for total in totals {
            for config in configs {
                let shares = BucketService.splitPennies(total,
                                                        spendPercent: config.spend,
                                                        shortPercent: config.short,
                                                        longPercent: config.long)
                #expect(shares.reduce(0) { $0 + $1.pennies } == total,
                        "\(config) at \(total) pennies must conserve the total")
                #expect(shares.allSatisfy { $0.pennies >= 0 })
            }
        }
    }

    // MARK: - Balance Attribution

    @Test
    func `bucket balances attribute only bucketKind tagged entries`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cache = try CacheService(inMemory: true)
        let buckets = BucketService(cacheService: cache)
        let familyRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
        )
        let profileRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "hero1", zoneID: zoneID), action: .none
        )

        func entry(_ name: String, amount: Double, bucketKind: String?) -> LedgerEntry {
            LedgerEntry(
                profile: profileRef,
                amount: amount,
                description: name,
                source: "quest",
                bucketKind: bucketKind,
                family: familyRef,
                id: CKRecord.ID(recordName: name, zoneID: zoneID)
            )
        }

        await cache.upsertLedgerEntry(entry("a-spend", amount: 15.0, bucketKind: BucketKind.spend.rawValue))
        await cache.upsertLedgerEntry(entry("b-short", amount: 6.25, bucketKind: BucketKind.shortTermSave.rawValue))
        // Negative amounts are spending drawn out of an attributed bucket.
        await cache.upsertLedgerEntry(entry("c-spend-drain", amount: -5.0, bucketKind: BucketKind.spend.rawValue))
        // Legacy unattributed row predating V8 stays out of bucket totals.
        await cache.upsertLedgerEntry(entry("d-legacy", amount: 9.0, bucketKind: nil))
        // Unknown raw values must never silently become a bucket.
        await cache.upsertLedgerEntry(entry("e-vault", amount: 4.0, bucketKind: "vault"))

        let balances = buckets.bucketBalances(profileRecordName: "hero1", familyRecordName: "fam1")
        #expect(balances[.spend] == 10.0)
        #expect(balances[.shortTermSave] == 6.25)
        #expect(balances[.longTermSave] == nil)
        #expect(balances.count == 2)
    }

    @Test
    func `bucket balances without a cache are empty`() {
        let buckets = BucketService()
        #expect(buckets.bucketBalances(profileRecordName: "hero1", familyRecordName: "fam1").isEmpty)
    }

    // MARK: - Payout Integration

    /// Scaffold mirroring the weekly payout flow: Guild Master finalizes a
    /// batch-hero week whose earnings live in the fresh cache.
    @MainActor
    struct PayoutSplitScaffold {
        let zoneID: CKRecordZone.ID
        let cloudKit: any CloudKitServiceProtocol
        let cache: CacheService
        let appState: AppState
        let treasury: TreasuryService
        let hero: Profile
        let guildMaster: Profile
        let family: Family
        let weekOf: Date

        init(spendPercent: Int = 100,
             shortPercent: Int = 0,
             longPercent: Int = 0,
             policy: PayoutPolicy = .perQuest) throws
        {
            zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
            let mock = MockCloudKitService()
            mock.activeFamilyZoneID = zoneID
            cloudKit = mock
            cache = try CacheService(inMemory: true)
            appState = AppState()
            treasury = TreasuryService(cloudKit: cloudKit, cacheService: cache, appState: appState)

            let familyRef = CKRecord.Reference(
                recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
            )
            let heroID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
            hero = Profile(
                displayName: "Hero",
                role: .hero,
                iCloudUserID: heroID,
                family: familyRef,
                payoutPolicy: policy,
                splitPercentSpend: spendPercent,
                splitPercentShort: shortPercent,
                splitPercentLong: longPercent,
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
            weekOf = WeekMath.mondayOfWeek(for: Date())

            mock.seedMockRecords([hero, guildMaster, family])
            cache.context?.insert(ProfileCache(from: hero))
            cache.context?.insert(ProfileCache(from: guildMaster))
            cache.context?.insert(FamilyCache(from: family))
            _ = cache.saveContext()
            cache.markCacheFreshForTests(familyRecordName: family.id.recordName, type: .profile)
            cache.markCacheFreshForTests(familyRecordName: family.id.recordName, type: .family)
        }

        func seedEarned(goldReward: Double = 25.0) {
            let templateRef = CKRecord.Reference(
                recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none
            )
            let quest = Quest(
                template: templateRef,
                assignee: CKRecord.Reference(recordID: hero.id, action: .none),
                goldReward: goldReward,
                xpReward: 50,
                scheduleType: .weeklyFlexible,
                targetCount: 1,
                isAllOrNothing: false,
                approvalMode: .autoApprove,
                weekOf: weekOf,
                createdBy: CKRecord.Reference(recordID: family.id, action: .none),
                family: CKRecord.Reference(recordID: family.id, action: .none),
                name: "Payout Quest",
                id: CKRecord.ID(recordName: "quest1", zoneID: zoneID)
            )
            let completion = QuestCompletion(
                quest: CKRecord.Reference(recordID: quest.id, action: .none),
                completedBy: CKRecord.Reference(recordID: hero.id, action: .none),
                approvalMode: .autoApprove,
                weekOf: weekOf,
                family: CKRecord.Reference(recordID: family.id, action: .none)
            )
            cache.context?.insert(QuestCache(from: quest))
            cache.context?.insert(QuestCompletionCache(from: completion))
            _ = cache.saveContext()
            cache.markCacheFreshForTests(familyRecordName: family.id.recordName, type: .quest)
            cache.markCacheFreshForTests(familyRecordName: family.id.recordName, type: .questCompletion)
            cache.markCacheFreshForTests(familyRecordName: family.id.recordName, type: .allowancePeriod)
            cache.markCacheFreshForTests(familyRecordName: family.id.recordName, type: .ledgerEntry)
        }

        func payOut() async throws -> AllowancePeriod {
            appState.currentProfile = guildMaster
            let period = try await treasury.getOrCreateAllowancePeriod(
                profile: hero,
                weekOf: weekOf,
                family: family
            )
            try await treasury.runPayout(period: period)
            return try #require(
                cache.fetchAllowancePeriod(recordName: period.id.recordName, family: family.id.recordName)?
                    .toAllowancePeriod(zoneID: zoneID)
            )
        }

        func ledgerEntries() -> [LedgerEntryCache] {
            cache.fetchLedgerEntries(
                profileRecordName: hero.id.recordName,
                family: family.id.recordName
            )
        }
    }

    @Test
    func `multi bucket payout mints one attributed entry per receiving bucket`() async throws {
        let scaffold = try PayoutSplitScaffold(spendPercent: 60, shortPercent: 25, longPercent: 15)
        scaffold.seedEarned()

        let paid = try await scaffold.payOut()

        #expect(paid.status == .paid)
        #expect(paid.paidAmount == 25.0)

        let entries = scaffold.ledgerEntries().sorted { $0.recordName < $1.recordName }
        #expect(entries.count == 3, "Multi-bucket payout mints exactly one entry per receiving bucket")

        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.recordName, $0) })
        let base = "payout-\(paid.id.recordName)"
        #expect(byName["\(base)-spend"]?.amount == 15.0)
        #expect(byName["\(base)-shortTermSave"]?.amount == 6.25)
        #expect(byName["\(base)-longTermSave"]?.amount == 3.75)
        #expect(byName["\(base)-spend"]?.bucketKind == BucketKind.spend.rawValue)
        #expect(byName["\(base)-shortTermSave"]?.bucketKind == BucketKind.shortTermSave.rawValue)
        #expect(byName["\(base)-longTermSave"]?.bucketKind == BucketKind.longTermSave.rawValue)
        #expect(entries.allSatisfy { $0.source == "quest" })

        // Pennies must sum back to the exact payout total in the wallet.
        let balance = try await scaffold.treasury.currentBalance(for: scaffold.hero)
        #expect(balance == 25.0)
    }

    @Test
    func `default single bucket payout keeps the legacy record name`() async throws {
        let scaffold = try PayoutSplitScaffold(spendPercent: 100, shortPercent: 0, longPercent: 0)
        scaffold.seedEarned()

        let paid = try await scaffold.payOut()

        let entries = scaffold.ledgerEntries()
        #expect(entries.count == 1)
        #expect(entries.first?.recordName == "payout-\(paid.id.recordName)")
        #expect(entries.first?.amount == 25.0)
        #expect(entries.first?.bucketKind == BucketKind.spend.rawValue)
    }

    @Test
    func `replayed bucket payout does not double mint entries`() async throws {
        let scaffold = try PayoutSplitScaffold(spendPercent: 60, shortPercent: 25, longPercent: 15)
        scaffold.seedEarned()

        let paid = try await scaffold.payOut()

        // Replay the settlement step directly — the deterministic-ID guard in
        // the engine must no-op even if the caller bypasses the paid-period
        // skip-guard.
        await scaffold.treasury.mintBucketSplitPayout(
            periodRecordName: paid.id.recordName,
            amount: paid.paidAmount ?? 0,
            weekOf: paid.weekOf,
            profile: scaffold.hero,
            family: paid.family,
            date: Date(),
            isOwner: true
        )

        #expect(scaffold.ledgerEntries().count == 3)
    }

    // MARK: - Deterministic TransferID — Midnight Skew Atomicity

    @Test
    func `deterministicTransferID consistent when Date captured once near UTC midnight`() {
        // WHY single capture: `WeekMath.dayBucket(for:)` quantizes at UTC midnight; two `Date()`
        // calls straddling 00:00 UTC would yield different buckets. Capturing `Date()` once
        // and reusing for bucket + ID keeps view/service atomic.
        let secondsPerDay: Double = 86400
        // Arbitrary stable epoch day to avoid DST/timezone influence — UTC bucket only.
        let baseDay = 19700
        let baseStart = Double(baseDay) * secondsPerDay
        // 23:00 UTC — within 2h of midnight threshold on same UTC day.
        let dateA = Date(timeIntervalSince1970: baseStart + 23 * 3600)
        // 23:50 UTC — still same UTC day, 50 min later, still within 2h window.
        let dateB = dateA.addingTimeInterval(50 * 60)
        // Verify both dates quantize to the same UTC bucket via `WeekMath` (single-capture contract).
        let bucketA = WeekMath.dayBucket(for: dateA)
        let bucketB = WeekMath.dayBucket(for: dateB)
        #expect(bucketA == bucketB, "Two Dates within same UTC day must yield same dayBucket")
        #expect(WeekMath.isNearUTCMidnight(dateA), "23:00 is within 2h of UTC midnight")
        #expect(WeekMath.isNearUTCMidnight(dateB), "23:50 is within 2h of UTC midnight")

        // Deterministic ID derived from a single-captured bucket must be stable.
        let idA = BucketService.deterministicTransferID(dayBucket: bucketA, from: .spend, to: .shortTermSave)
        let idB = BucketService.deterministicTransferID(dayBucket: bucketB, from: .spend, to: .shortTermSave)
        #expect(idA == idB, "Same UTC bucket + pair must produce identical transferID")

        // Capturing once: re-deriving from the same mocked Date yields identical ID.
        let idA2 = BucketService.deterministicTransferID(
            dayBucket: WeekMath.dayBucket(for: dateA),
            from: .spend,
            to: .shortTermSave
        )
        #expect(idA2 == idA, "Re-capturing same instant must stay consistent")

        // Cross-midnight: 00:10 UTC next day must be a different bucket/ID, but each side
        // remains self-consistent when its own Date is captured once.
        let dateAfterMidnight = dateB.addingTimeInterval(20 * 60) // 00:10 next UTC day
        let bucketC = WeekMath.dayBucket(for: dateAfterMidnight)
        #expect(bucketC == bucketA + 1, "00:10 UTC next day must be next bucket")
        let idC = BucketService.deterministicTransferID(dayBucket: bucketC, from: .spend, to: .shortTermSave)
        #expect(idC != idA, "Next UTC day must produce distinct transferID for same pair")
        #expect(WeekMath.isNearUTCMidnight(dateAfterMidnight), "00:10 is within 2h of UTC midnight")
    }
}
