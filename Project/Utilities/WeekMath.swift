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

    static func weekOf(date: Date) -> Date {
        mondayOfWeek(for: date)
    }

    static func weekRange(starting start: Date) -> Range<Date> {
        let cal = Calendar.iso8601UTC
        let normalizedStart = cal.startOfDay(for: start)
        let end = normalizedStart.addingTimeInterval(TimeInterval(secondsInWeek))
        return normalizedStart ..< end
    }
}
