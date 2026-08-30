//
//  WidgetDataBridgeTests.swift
//  LootListTests
//
//  Created by Ben Mackin on 8/29/26.
//

import Foundation
@testable import LootList
import Testing

struct WidgetDataBridgeTests {
    @Test
    func `widget snapshot progress fraction`() {
        let empty = WidgetSnapshot(todayCompletedQuests: 0, todayTotalQuests: 0)
        #expect(empty.questProgressFraction == 0.0)

        let half = WidgetSnapshot(todayCompletedQuests: 2, todayTotalQuests: 4)
        #expect(half.questProgressFraction == 0.5)

        let complete = WidgetSnapshot(todayCompletedQuests: 5, todayTotalQuests: 4)
        #expect(complete.questProgressFraction == 1.0)
    }

    @Test
    func `widget snapshot encoding decoding round trip`() throws {
        let snapshot = WidgetSnapshot(
            todayCompletedQuests: 3,
            todayTotalQuests: 5,
            dailyQuestStreak: 7,
            weeklySavingsStreak: 12,
            activeGoalName: "Drone",
            activeGoalTargetPennies: 5000,
            activeGoalSavedPennies: 3000,
            activeGoalEmoji: "🛸",
            nextQuestTitle: "Take out Trash",
            lastUpdated: Date()
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(snapshot)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(WidgetSnapshot.self, from: data)

        #expect(decoded.todayCompletedQuests == 3)
        #expect(decoded.todayTotalQuests == 5)
        #expect(decoded.dailyQuestStreak == 7)
        #expect(decoded.weeklySavingsStreak == 12)
        #expect(decoded.activeGoalName == "Drone")
        #expect(decoded.nextQuestTitle == "Take out Trash")
    }

    @Test
    func `widget data bridge save and load`() {
        let testSnapshot = WidgetSnapshot(
            todayCompletedQuests: 4,
            todayTotalQuests: 4,
            dailyQuestStreak: 9,
            weeklySavingsStreak: 15,
            activeGoalName: "Rollerblades",
            lastUpdated: Date()
        )

        WidgetDataBridge.saveSnapshot(testSnapshot)
        let loaded = WidgetDataBridge.loadSnapshot()

        #expect(loaded.todayCompletedQuests == 4)
        #expect(loaded.dailyQuestStreak == 9)
        #expect(loaded.activeGoalName == "Rollerblades")
    }
}
