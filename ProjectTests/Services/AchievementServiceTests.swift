//
//  AchievementServiceTests.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct AchievementServiceTests {
    private func makeDependencies() -> (AchievementService, CloudKitService) {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = CloudKitService(zoneID: zoneID)
        let achievementService = AchievementService(cloudKit: cloudKit)
        return (achievementService, cloudKit)
    }

    @Test
    func `achievement requirement raw values`() {
        #expect(AchievementRequirement.firstQuest.rawValue == "firstQuest")
        #expect(AchievementRequirement.questCount10.rawValue == "questCount10")
        #expect(AchievementRequirement.questCount50.rawValue == "questCount50")
        #expect(AchievementRequirement.questCount100.rawValue == "questCount100")
        #expect(AchievementRequirement.weekly100.rawValue == "weekly100")
        #expect(AchievementRequirement.streak7.rawValue == "streak7")
        #expect(AchievementRequirement.streak30.rawValue == "streak30")
        #expect(AchievementRequirement.gold100.rawValue == "gold100")
        #expect(AchievementRequirement.gold500.rawValue == "gold500")
        #expect(AchievementRequirement.ledgerCount10.rawValue == "ledgerCount10")
        #expect(AchievementRequirement.ledgerWeeks4.rawValue == "ledgerWeeks4")
        #expect(AchievementRequirement.earlyBird9am.rawValue == "earlyBird9am")
    }

    @Test
    func `achievement category raw values`() {
        #expect(AchievementCategory.quest.rawValue == "quest")
        #expect(AchievementCategory.streak.rawValue == "streak")
        #expect(AchievementCategory.gold.rawValue == "gold")
        #expect(AchievementCategory.special.rawValue == "special")
    }

    @Test
    func `profile stats model initialization`() {
        let stats = ProfileStats(
            questCount: 15,
            bestWeeklyCompletion: 1.0,
            longestStreakDays: 8,
            totalGoldEarned: 120.0,
            ledgerCount: 12,
            ledgerWeeksCount: 5,
            earlyBirdQualified: true
        )

        #expect(stats.questCount == 15)
        #expect(stats.bestWeeklyCompletion == 1.0)
        #expect(stats.longestStreakDays == 8)
        #expect(stats.totalGoldEarned == 120.0)
        #expect(stats.ledgerCount == 12)
        #expect(stats.ledgerWeeksCount == 5)
        #expect(stats.earlyBirdQualified == true)
    }
}
