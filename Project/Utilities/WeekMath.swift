//
//  WeekMath.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation

enum WeekMath {
    private static var secondsInWeek: Int {
        AppConstants.Time.secondsInWeek
    }

    static func mondayOfWeek(for date: Date) -> Date {
        let cal = Calendar.iso8601UTC
        let components = cal.dateComponents(
            [.yearForWeekOfYear, .weekOfYear], from: date
        )
        return cal.date(from: components) ?? cal.startOfDay(for: date)
    }

    static func startOfWeek(for date: Date, payoutDay: PayoutDay = .sunday) -> Date {
        let cal = Calendar.iso8601UTC
        let startOfDay = cal.startOfDay(for: date)
        let targetWeekday = payoutDay.calendarWeekday

        // Find the start of the payout cycle. If payoutDay is Sunday (weekday 1), cycle starts Monday (weekday 2).
        let cycleStartWeekday = (targetWeekday % 7) + 1
        let currentWeekday = cal.component(.weekday, from: startOfDay)

        let daysToSubtract = (currentWeekday - cycleStartWeekday + 7) % 7

        return cal.date(byAdding: .day, value: -daysToSubtract, to: startOfDay) ?? startOfDay
    }

    static func weekOf(date: Date, payoutDay: PayoutDay = .sunday) -> Date {
        startOfWeek(for: date, payoutDay: payoutDay)
    }

    static func weekRange(starting start: Date) -> Range<Date> {
        let cal = Calendar.iso8601UTC
        let normalizedStart = cal.startOfDay(for: start)
        let end = normalizedStart.addingTimeInterval(TimeInterval(secondsInWeek))
        return normalizedStart ..< end
    }
}
