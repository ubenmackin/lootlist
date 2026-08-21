//
//  WeekMath.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation

enum WeekMath {
    /// (targetWeekday%7)+1 rotates payoutDay to cycle start — Sat 7 wraps to Sun 1; iso8601UTC is UTC no-DST.
    /// weekRange is half-open [start,end) — end exclusive, Date==end is next week (gate at Monday 00:00).
    static func startOfWeek(for date: Date, payoutDay: PayoutDay = .sunday) -> Date {
        let cal = Calendar.iso8601UTC
        let startOfDay = cal.startOfDay(for: date)
        let targetWeekday = payoutDay.calendarWeekday
        let cycleStartWeekday = (targetWeekday % 7) + 1
        let currentWeekday = cal.component(.weekday, from: startOfDay)
        let daysToSubtract = (currentWeekday - cycleStartWeekday + 7) % 7
        return cal.date(byAdding: .day, value: -daysToSubtract, to: startOfDay) ?? startOfDay
    }

    static func mondayOfWeek(for date: Date) -> Date {
        startOfWeek(for: date, payoutDay: .sunday)
    }

    static func weekOf(date: Date, payoutDay: PayoutDay = .sunday) -> Date {
        startOfWeek(for: date, payoutDay: payoutDay)
    }

    static func weekRange(starting start: Date) -> Range<Date> {
        let cal = Calendar.iso8601UTC
        let normalizedStart = cal.startOfDay(for: start)
        let end = normalizedStart.addingTimeInterval(TimeInterval(AppConstants.Time.secondsInWeek))
        return normalizedStart ..< end
    }
}
