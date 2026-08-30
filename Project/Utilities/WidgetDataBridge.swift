//
//  WidgetDataBridge.swift
//  LootList
//
//  Created by Ben Mackin on 8/29/26.
//

import Foundation
import os
#if canImport(WidgetKit)
    import WidgetKit
#endif

/// Snapshot model shared between the main app and the WidgetKit extension via App Group UserDefaults.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public var todayCompletedQuests: Int
    public var todayTotalQuests: Int
    public var dailyQuestStreak: Int
    public var weeklySavingsStreak: Int
    public var activeGoalName: String?
    public var activeGoalTargetPennies: Int64?
    public var activeGoalSavedPennies: Int64?
    public var activeGoalEmoji: String?
    public var nextQuestTitle: String?
    public var lastUpdated: Date

    public var questProgressFraction: Double {
        guard todayTotalQuests > 0 else { return 0 }
        return min(max(Double(todayCompletedQuests) / Double(todayTotalQuests), 0), 1)
    }

    public init(
        todayCompletedQuests: Int = 0,
        todayTotalQuests: Int = 0,
        dailyQuestStreak: Int = 0,
        weeklySavingsStreak: Int = 0,
        activeGoalName: String? = nil,
        activeGoalTargetPennies: Int64? = nil,
        activeGoalSavedPennies: Int64? = nil,
        activeGoalEmoji: String? = nil,
        nextQuestTitle: String? = nil,
        lastUpdated: Date = Date()
    ) {
        self.todayCompletedQuests = todayCompletedQuests
        self.todayTotalQuests = todayTotalQuests
        self.dailyQuestStreak = dailyQuestStreak
        self.weeklySavingsStreak = weeklySavingsStreak
        self.activeGoalName = activeGoalName
        self.activeGoalTargetPennies = activeGoalTargetPennies
        self.activeGoalSavedPennies = activeGoalSavedPennies
        self.activeGoalEmoji = activeGoalEmoji
        self.nextQuestTitle = nextQuestTitle
        self.lastUpdated = lastUpdated
    }

    public static let empty = WidgetSnapshot(
        todayCompletedQuests: 0,
        todayTotalQuests: 0,
        dailyQuestStreak: 0,
        weeklySavingsStreak: 0,
        activeGoalName: nil,
        nextQuestTitle: nil,
        lastUpdated: Date()
    )

    public static let placeholder = WidgetSnapshot(
        todayCompletedQuests: 3,
        todayTotalQuests: 4,
        dailyQuestStreak: 5,
        weeklySavingsStreak: 8,
        activeGoalName: "New Bike",
        activeGoalTargetPennies: 12000,
        activeGoalSavedPennies: 7500,
        activeGoalEmoji: "🚲",
        nextQuestTitle: "Clean Room",
        lastUpdated: Date()
    )
}

public enum WidgetDataBridge {
    public static let appGroupID = "group.com.volcrypt.lootlist"
    private static let snapshotKey = "lootlist_widget_snapshot"

    public static var sharedDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    public static func loadSnapshot() -> WidgetSnapshot {
        guard let data = sharedDefaults.data(forKey: snapshotKey) else {
            return .empty
        }
        do {
            return try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        } catch {
            return .empty
        }
    }

    private static let logger = Logger(subsystem: "com.volcrypt.lootlist", category: "WidgetDataBridge")

    public static func saveSnapshot(_ snapshot: WidgetSnapshot) {
        do {
            let data = try JSONEncoder().encode(snapshot)
            sharedDefaults.set(data, forKey: snapshotKey)
            #if canImport(WidgetKit)
                WidgetCenter.shared.reloadAllTimelines()
            #endif
        } catch {
            logger.warning("Failed to encode widget data snapshot: \(error, privacy: .private)")
        }
    }
}
