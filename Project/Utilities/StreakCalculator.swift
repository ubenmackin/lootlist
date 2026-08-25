//
//  StreakCalculator.swift
//  LootList
//
//  Created by Ben Mackin on 8/4/26.
//

import Foundation

enum StreakCalculator {
    /// Daily quest-completion streak (verified or auto-approved completions only).
    nonisolated static func computeStreak(from logs: [QuestCompletionCache]) -> Int {
        let calendar = Calendar.iso8601UTC
        var daySet: Set<Date> = []
        for log in logs where
            log.verificationStatusEnum == .autoApproved
            || log.verificationStatusEnum == .verified
        {
            if let day = calendar.dateInterval(of: .day, for: log.completedDate)?.start {
                daySet.insert(day)
            }
        }

        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let anchor = daySet.contains(today) ? today
            : (daySet.contains(yesterday) ? yesterday : nil)
        guard let anchor else { return 0 }

        var streak = 0
        var cursor = anchor
        while daySet.contains(cursor) {
            streak += 1
            guard let previousDay = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previousDay
        }
        return streak
    }

    /// Weekly savings-streak: counts consecutive recent weeks in which the hero
    /// made at least one contribution to a save bucket (short-term or long-term).
    nonisolated static func computeSavingsStreak(
        from ledgers: [LedgerEntryCache],
        profileRecordName: String
    ) -> Int {
        let calendar = Calendar.iso8601UTC
        var weekSet: Set<Date> = []

        for entry in ledgers where
            entry.profileRecordName == profileRecordName
            && (entry.bucketKind == "shortTermSave" || entry.bucketKind == "longTermSave")
            && entry.amount > 0
        {
            if let weekStart = calendar.dateInterval(of: .weekOfYear, for: entry.date)?.start {
                weekSet.insert(weekStart)
            }
        }

        let now = Date()
        guard let thisWeekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return 0 }
        let lastWeekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeekStart) ?? thisWeekStart
        let anchor = weekSet.contains(thisWeekStart) ? thisWeekStart
            : (weekSet.contains(lastWeekStart) ? lastWeekStart : nil)
        guard let anchor else { return 0 }

        var streak = 0
        var cursor = anchor
        while weekSet.contains(cursor) {
            streak += 1
            guard let previousWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: cursor) else { break }
            cursor = previousWeek
        }
        return streak
    }

    /// Milestone thresholds for streak-based rewards. Each threshold unlocks
    /// the corresponding reward tier — badges on the profile card and, at
    /// higher tiers, alternate app icons become selectable in Settings.
    enum StreakMilestone: Int, CaseIterable {
        case week1 = 1
        case week2 = 2
        case week4 = 4
        case week8 = 8
        case week12 = 12
        case week26 = 26

        var badgeLabel: String {
            switch self {
            case .week1: "Fresh Start"
            case .week2: "Getting Going"
            case .week4: "Monthly Saver"
            case .week8: "Dedicated Saver"
            case .week12: "Quarter Champion"
            case .week26: "Half-Year Hero"
            }
        }

        var iconName: String {
            switch self {
            case .week1: "AppIcon-Week1"
            case .week2: "AppIcon-Week2"
            case .week4: "AppIcon-Week4"
            case .week8: "AppIcon-Week8"
            case .week12: "AppIcon-Week12"
            case .week26: "AppIcon-Week26"
            }
        }

        /// All milestones that the given streak has reached or surpassed.
        static func unlockedMilestones(for streak: Int) -> [StreakMilestone] {
            StreakMilestone.allCases.filter { streak >= $0.rawValue }
        }
    }
}
