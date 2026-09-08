//
//  DashboardMetricsCalculatorTests.swift
//  LootList
//
//  Created by Ben Mackin on 9/6/26.
//

import Foundation
@testable import LootList
import Testing

struct DashboardMetricsCalculatorTests {
    @Test
    func `calculate filters out non-hero allowance periods from pastPayouts`() {
        let heroProfile = ProfileCache(
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
        let parentProfile = ProfileCache(
            recordName: "parent1",
            familyRecordName: "fam1",
            displayName: "Parent One",
            role: UserRole.guildMaster.rawValue,
            xpTotal: 0,
            avatarName: nil,
            customAvatarImageData: nil,
            isActive: true,
            level: 1,
            iCloudUserRecordName: "u_parent1",
            avatarClass: nil
        )

        let heroPeriod = AllowancePeriodCache(
            recordName: "period_hero1",
            profileRecordName: "hero1",
            familyRecordName: "fam1",
            weekOf: Date(),
            status: PayoutStatus.active.rawValue,
            totalEarned: 1000,
            questsCompleted: 2,
            questsTotal: 2
        )
        let parentPeriod = AllowancePeriodCache(
            recordName: "period_parent1",
            profileRecordName: "parent1",
            familyRecordName: "fam1",
            weekOf: Date(),
            status: PayoutStatus.active.rawValue,
            totalEarned: 0,
            questsCompleted: 0,
            questsTotal: 0
        )

        let metrics = DashboardMetricsCalculator.calculate(
            profiles: [heroProfile, parentProfile],
            quests: [],
            logs: [],
            ledgers: [],
            allowancePeriods: [heroPeriod, parentPeriod],
            profileAchievements: [],
            familyContext: DashboardMetricsCalculator.FamilyContext(recordName: "fam1"),
            templates: []
        )

        #expect(metrics.pastPayouts.count == 1)
        #expect(metrics.pastPayouts.first?.recordName == "period_hero1")
        #expect(!metrics.pastPayouts.contains(where: { $0.profileRecordName == "parent1" }))
    }
}
