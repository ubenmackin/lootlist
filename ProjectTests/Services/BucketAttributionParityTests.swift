//
//  BucketAttributionParityTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/29/26.
//

import Foundation
@testable import LootList
import Testing

@MainActor
struct BucketAttributionParityTests {
    private func makeLedger(
        recordName: String,
        profileRecordName: String = "hero1",
        amount: Double,
        source: String,
        bucketKind: String?,
        fromBucket: String? = nil,
        toBucket: String? = nil
    ) -> LedgerEntryCache {
        LedgerEntryCache(
            recordName: recordName,
            profileRecordName: profileRecordName,
            familyRecordName: "fam1",
            amount: amount,
            entryDescription: recordName,
            location: nil,
            date: Date(),
            source: source,
            bucketKind: bucketKind,
            fromBucket: fromBucket,
            toBucket: toBucket
        )
    }

    @Test
    func `bucket attribution parity across BucketService and DashboardMetricsCalculator including transfer`() {
        let ledgers = [
            makeLedger(recordName: "l_spend", amount: 10, source: "quest", bucketKind: BucketKind.spend.rawValue),
            makeLedger(
                recordName: "l_transfer",
                amount: 3,
                source: "transfer",
                bucketKind: BucketKind.shortTermSave.rawValue,
                fromBucket: BucketKind.spend.rawValue,
                toBucket: BucketKind.shortTermSave.rawValue
            ),
            makeLedger(recordName: "l_other_hero", profileRecordName: "hero2", amount: 99, source: "quest", bucketKind: BucketKind.spend.rawValue)
        ]

        let directBalances = BucketService.bucketBalances(for: ledgers, profileRecordName: "hero1")
        #expect(directBalances[.spend] == 7)
        #expect(directBalances[.shortTermSave] == 3)
        #expect(directBalances[.longTermSave] == nil || directBalances[.longTermSave] == 0)

        let directLedgerBalance = BucketService.ledgerBalance(for: ledgers, profileRecordName: "hero1")
        #expect(directLedgerBalance == 13)

        let heroRows = LedgerRowFactory.spendingRows(from: ledgers, profileRecordName: "hero1", scope: .allTime, payoutDay: .sunday)
        #expect(heroRows.count == 2)
        #expect(Set(heroRows.map(\.id)) == Set(["l_spend", "l_transfer"]))

        let hero = ProfileCache(
            recordName: "hero1",
            familyRecordName: "fam1",
            displayName: "Hero One",
            role: UserRole.hero.rawValue,
            xpTotal: 0,
            avatarName: nil,
            customAvatarImageData: nil,
            isActive: true,
            level: 1,
            iCloudUserRecordName: "u_hero1",
            avatarClass: nil
        )
        let hero2 = ProfileCache(
            recordName: "hero2",
            familyRecordName: "fam1",
            displayName: "Hero Two",
            role: UserRole.hero.rawValue,
            xpTotal: 0,
            avatarName: nil,
            customAvatarImageData: nil,
            isActive: true,
            level: 1,
            iCloudUserRecordName: "u_hero2",
            avatarClass: nil
        )
        let metrics = DashboardMetricsCalculator.calculate(
            profiles: [hero, hero2],
            quests: [],
            logs: [],
            ledgers: ledgers,
            allowancePeriods: [],
            profileAchievements: []
        )
        let heroCard = metrics.childAccountCards.first { $0.profile.recordName == "hero1" }
        #expect(heroCard?.balance == 10)
        #expect((heroCard?.balance ?? 0) == (directBalances.values.reduce(0, +)))
        #expect(metrics.familyOutflow == 10 + 99)
    }
}
