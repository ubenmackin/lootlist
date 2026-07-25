//
//  TreasuryServiceTests.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct TreasuryServiceTests {
    private func makeTestData() -> (TreasuryService, CloudKitService) {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = CloudKitService(zoneID: zoneID)
        let treasury = TreasuryService(cloudKit: cloudKit)
        return (treasury, cloudKit)
    }

    @Test
    func `monday of week calculation`() {
        let now = Date()
        let monday = TreasuryService.mondayOfWeek(for: now)
        let cal = Calendar.iso8601UTC

        // Monday start of day check
        let weekday = cal.component(.weekday, from: monday)
        #expect(weekday == 2) // 2 represents Monday in ISO8601 calendar
    }

    @Test
    func `week range interval calculation`() {
        let monday = TreasuryService.mondayOfWeek(for: Date())
        let interval = TreasuryService.weekRange(starting: monday)

        let durationSeconds = interval.end.timeIntervalSince(interval.start)
        #expect(durationSeconds == Double(AppConstants.Time.secondsInWeek - 1))
    }

    @Test
    func `weekly breakdown default initialization`() {
        let breakdown = TreasuryService.WeeklyBreakdown()
        #expect(breakdown.questsCount == 0)
        #expect(breakdown.goldFromQuests == 0)
        #expect(breakdown.bonusGold == 0)
        #expect(breakdown.totalEarned == 0)
        #expect(breakdown.spent == 0)
        #expect(breakdown.net == 0)
    }
}
