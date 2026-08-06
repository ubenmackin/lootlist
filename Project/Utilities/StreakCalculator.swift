//
//  StreakCalculator.swift
//  LootList
//
//  Created by Ben Mackin on 2026-08-04
//

import Foundation

enum StreakCalculator {
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
}
