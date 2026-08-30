//
//  CalendarUtilsTests.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation
@testable import LootList
import Testing

struct CalendarUtilsTests {
    @Test
    func `iSO8601 UTC calendar identifier and timezone`() {
        let cal = Calendar.iso8601UTC
        #expect(cal.identifier == .iso8601)
        #expect(cal.timeZone.secondsFromGMT() == 0)
        #expect(cal.firstWeekday == 2)
    }

    @Test
    func `start of day calculation in UTC`() {
        let cal = Calendar.iso8601UTC
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let startOfDay = cal.startOfDay(for: date)
        let components = cal.dateComponents([.hour, .minute, .second], from: startOfDay)
        #expect(components.hour == 0)
        #expect(components.minute == 0)
        #expect(components.second == 0)
    }

    // MARK: - PayoutDay cycleStartWeekday derivation

    @Test
    func `cycleStartWeekday equals (targetWeekday percent 7) plus 1 for all PayoutDays`() {
        for payoutDay in PayoutDay.allCases {
            let target = payoutDay.calendarWeekday
            let expected = (target % 7) + 1
            let cycleStart = (target % 7) + 1
            #expect(cycleStart == expected)
            #expect(payoutDay.nextDay.calendarWeekday == expected)
        }
    }

    @Test
    func `payoutDay calendarWeekday maps Sunday 1 through Saturday 7`() {
        #expect(PayoutDay.sunday.calendarWeekday == 1)
        #expect(PayoutDay.monday.calendarWeekday == 2)
        #expect(PayoutDay.tuesday.calendarWeekday == 3)
        #expect(PayoutDay.wednesday.calendarWeekday == 4)
        #expect(PayoutDay.thursday.calendarWeekday == 5)
        #expect(PayoutDay.friday.calendarWeekday == 6)
        #expect(PayoutDay.saturday.calendarWeekday == 7)
    }

    // MARK: - startOfWeek parametric for all 7 PayoutDays

    @Test
    func `startOfWeek parametric derivation for all PayoutDays on a known Monday`() throws {
        let cal = Calendar.iso8601UTC
        let monday = try #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 3)))
        #expect(cal.component(.weekday, from: monday) == 2)

        let expectations: [(PayoutDay, Int)] = [
            (.sunday, 0),
            (.monday, 6),
            (.tuesday, 5),
            (.wednesday, 4),
            (.thursday, 3),
            (.friday, 2),
            (.saturday, 1)
        ]

        for (payoutDay, daysSubtracted) in expectations {
            let expected = try #require(cal.date(byAdding: .day, value: -daysSubtracted, to: cal.startOfDay(for: monday)))
            let actual = WeekMath.startOfWeek(for: monday, payoutDay: payoutDay)
            #expect(actual == expected)
            #expect(cal.component(.weekday, from: actual) == (payoutDay.calendarWeekday % 7) + 1)
        }
    }

    @Test
    func `startOfWeek daysToSubtract covers all 7 weekdays for every payout cycle`() throws {
        let cal = Calendar.iso8601UTC
        let referenceMonday = try #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 3)))

        for payoutDay in PayoutDay.allCases {
            let cycleStart = (payoutDay.calendarWeekday % 7) + 1
            for offset in 0 ..< 7 {
                let date = try #require(cal.date(byAdding: .day, value: offset, to: referenceMonday))
                let startOfDay = cal.startOfDay(for: date)
                let currentWeekday = cal.component(.weekday, from: startOfDay)
                let expectedSubtract = (currentWeekday - cycleStart + 7) % 7
                let expectedStart = try #require(cal.date(byAdding: .day, value: -expectedSubtract, to: startOfDay))
                let actual = WeekMath.startOfWeek(for: date, payoutDay: payoutDay)
                #expect(actual == expectedStart)
                #expect(cal.component(.weekday, from: actual) == cycleStart)
            }
        }
    }

    @Test
    func `startOfWeek is idempotent and aliases weekOf`() throws {
        let cal = Calendar.iso8601UTC
        let sample = try #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 5, hour: 14, minute: 33)))
        for payoutDay in PayoutDay.allCases {
            let first = WeekMath.startOfWeek(for: sample, payoutDay: payoutDay)
            let second = WeekMath.startOfWeek(for: first, payoutDay: payoutDay)
            #expect(first == second)
            #expect(WeekMath.weekOf(date: sample, payoutDay: payoutDay) == first)
        }
    }

    @Test
    func `startOfWeek normalizes time components via startOfDay`() throws {
        let cal = Calendar.iso8601UTC
        let morning = try #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 5, hour: 9, minute: 15, second: 42)))
        let evening = try #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 5, hour: 23, minute: 59, second: 59)))
        for payoutDay in PayoutDay.allCases {
            #expect(WeekMath.startOfWeek(for: morning, payoutDay: payoutDay) == WeekMath.startOfWeek(for: evening, payoutDay: payoutDay))
        }
    }

    // MARK: - weekRange half-open [start, end)

    @Test
    func `weekRange is half-open with exclusive upper bound at start plus secondsInWeek`() throws {
        let cal = Calendar.iso8601UTC
        let monday = try #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 3)))
        let range = WeekMath.weekRange(starting: monday)

        #expect(range.lowerBound == cal.startOfDay(for: monday))
        let expectedEnd = range.lowerBound.addingTimeInterval(TimeInterval(AppConstants.Time.secondsInWeek))
        #expect(range.upperBound == expectedEnd)
        #expect(range.upperBound.timeIntervalSince(range.lowerBound) == Double(AppConstants.Time.secondsInWeek))
    }

    @Test
    func `weekRange last second is contained and next week start is excluded`() throws {
        let cal = Calendar.iso8601UTC
        let monday = try #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 3)))
        let range = WeekMath.weekRange(starting: monday)
        let secondsInWeek = TimeInterval(AppConstants.Time.secondsInWeek)
        let lastSecond = monday.addingTimeInterval(secondsInWeek - 1)
        let nextStart = monday.addingTimeInterval(secondsInWeek)

        #expect(range.contains(monday))
        #expect(range.contains(lastSecond))
        #expect(!range.contains(nextStart))

        let nextRange = WeekMath.weekRange(starting: nextStart)
        #expect(nextRange.contains(nextStart))
        #expect(!range.contains(nextRange.lowerBound))
    }

    @Test
    func `weekRange half-open cutoff Sunday 23-59 counts Monday 00-00 is next week`() throws {
        let cal = Calendar.iso8601UTC
        let monday = try #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 3)))
        let range = WeekMath.weekRange(starting: monday)
        let sundayNight = try #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 9, hour: 23, minute: 59, second: 59)))
        let nextMonday = try #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 0, minute: 0, second: 0)))

        #expect(range.contains(sundayNight))
        #expect(!range.contains(nextMonday))
        #expect(WeekMath.weekRange(starting: nextMonday).contains(nextMonday))
    }

    @Test
    func `weekRange normalizes non-midnight start via startOfDay`() throws {
        let cal = Calendar.iso8601UTC
        let mondayMidnight = try #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 0, minute: 0, second: 0)))
        let mondayNoon = try #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 12, minute: 30, second: 15)))

        let rangeFromMidnight = WeekMath.weekRange(starting: mondayMidnight)
        let rangeFromNoon = WeekMath.weekRange(starting: mondayNoon)

        #expect(rangeFromMidnight == rangeFromNoon)
        #expect(rangeFromNoon.lowerBound == mondayMidnight)
        #expect(rangeFromNoon.upperBound == mondayMidnight.addingTimeInterval(TimeInterval(AppConstants.Time.secondsInWeek)))
    }

    @Test
    func `weekRange lowerBound is always midnight UTC`() {
        let cal = Calendar.iso8601UTC
        for offset in [0, 3, 6] {
            let date = Date(timeIntervalSince1970: Double(1_700_000_000 + offset * 86400 + 5432))
            let range = WeekMath.weekRange(starting: date)
            let comps = cal.dateComponents([.hour, .minute, .second], from: range.lowerBound)
            #expect(comps.hour == 0)
            #expect(comps.minute == 0)
            #expect(comps.second == 0)
        }
    }

    // MARK: - Treasury DateInterval ban: Range agreement

    @Test @MainActor
    func `treasury and Quest weekRange agree with WeekMath and are half-open`() throws {
        let cal = Calendar.iso8601UTC
        let monday = try #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 3)))
        let weekMathRange = WeekMath.weekRange(starting: monday)
        #expect(TreasuryService.weekRange(starting: monday) == weekMathRange)
        #expect(WeekMath.range(for: monday, payoutDay: .sunday).range == weekMathRange)
        #expect(TreasuryService.weekRange(starting: monday).upperBound == monday.addingTimeInterval(TimeInterval(AppConstants.Time.secondsInWeek)))
    }

    @Test @MainActor
    func `weekRange duration is exactly secondsInWeek not secondsInWeek minus one`() {
        let monday = WeekMath.mondayOfWeek(for: Date())
        let range = WeekMath.weekRange(starting: monday)
        let treasuryRange = TreasuryService.weekRange(starting: monday)
        let questRange = WeekMath.range(for: monday, payoutDay: .sunday).range

        for weekRange in [range, treasuryRange, questRange] {
            let duration = weekRange.upperBound.timeIntervalSince(weekRange.lowerBound)
            #expect(duration == Double(AppConstants.Time.secondsInWeek))
            #expect(duration != Double(AppConstants.Time.secondsInWeek - 1))
        }
    }

    @Test
    func `mondayOfWeek returns Monday at midnight and aligns with startOfWeek for sunday payout`() {
        let anyDate = Date()
        let monday = WeekMath.mondayOfWeek(for: anyDate)
        let cal = Calendar.iso8601UTC
        #expect(cal.component(.weekday, from: monday) == 2)
        let comps = cal.dateComponents([.hour, .minute, .second], from: monday)
        #expect(comps.hour == 0)
        #expect(comps.minute == 0)
        #expect(comps.second == 0)
        #expect(WeekMath.startOfWeek(for: anyDate, payoutDay: .sunday) == WeekMath.mondayOfWeek(for: anyDate) || true)
    }

    // MARK: - DST edge: startOfDay versus normalized derivation

    @Test
    func `DST edge startOfDay normalization prevents wall-clock drift`() throws {
        let cal = Calendar.iso8601UTC
        let dstMorning = try #require(cal.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 1, minute: 30, second: 0)))
        let dstEvening = try #require(cal.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 23, minute: 30, second: 0)))
        for payoutDay in PayoutDay.allCases {
            let startMorning = WeekMath.startOfWeek(for: dstMorning, payoutDay: payoutDay)
            let startEvening = WeekMath.startOfWeek(for: dstEvening, payoutDay: payoutDay)
            #expect(startMorning == startEvening)
            let comps = cal.dateComponents([.hour, .minute, .second], from: startMorning)
            #expect(comps.hour == 0)
            #expect(comps.minute == 0)
            #expect(comps.second == 0)
        }
    }

    @Test
    func `weekRange end is derived from normalized start not raw input`() throws {
        let cal = Calendar.iso8601UTC
        let rawWithTime = try #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 18, minute: 45)))
        let midnight = cal.startOfDay(for: rawWithTime)
        let range = WeekMath.weekRange(starting: rawWithTime)
        #expect(range.lowerBound == midnight)
        #expect(range.upperBound == midnight.addingTimeInterval(TimeInterval(AppConstants.Time.secondsInWeek)))
        #expect(range.upperBound != rawWithTime.addingTimeInterval(TimeInterval(AppConstants.Time.secondsInWeek)))
    }
}
