//
//  WeekMath.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation
import os

enum WeekMath {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "LootList",
        category: "WeekMath"
    )
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

    /// Atomically derives the payout-anchored week start and its half-open range
    /// from a single date and payoutDay, so [start, end) can never be built
    /// from mismatched inputs.
    static func range(for date: Date, payoutDay: PayoutDay) -> (start: Date, range: Range<Date>) {
        let start = startOfWeek(for: date, payoutDay: payoutDay)
        let range = weekRange(starting: start)
        return (start, range)
    }

    /// Steps an existing payout-cycle start whole weeks forward/backward. Cycle
    /// starts are UTC-midnight anchored on a fixed 7-day cadence, so whole-week
    /// day stepping is exact (no DST drift under iso8601UTC).
    static func weekStart(byAddingWeeks weekCount: Int, to start: Date) -> Date {
        let cal = Calendar.iso8601UTC
        return cal.date(byAdding: .day, value: weekCount * 7, to: cal.startOfDay(for: start)) ?? start
    }

    /// Weekday code for a given date — e.g. "monday" — aligned to iso8601UTC so
    /// hub/dashboard due-text matches the payout-anchored week strip.
    static func weekdayCode(for date: Date, calendar: Calendar = .iso8601UTC) -> String {
        let index = calendar.component(.weekday, from: date) - 1
        let codes = AppConstants.weekdayCodes
        return codes[max(0, min(codes.count - 1, index))]
    }

    static func todayWeekdayCode(calendar: Calendar = .iso8601UTC) -> String {
        weekdayCode(for: Date(), calendar: calendar)
    }

    /// Weekday codes spanned by the 7 days of a payout cycle starting at
    /// `weekOf` — schedule day-set derivation stays inside WeekMath.
    static func weekdayCodes(inWeekOf weekOf: Date) -> Set<String> {
        let cal = Calendar.iso8601UTC
        var found: Set<String> = []
        for offset in 0 ..< 7 {
            let day = cal.date(byAdding: .day, value: offset, to: weekOf) ?? weekOf
            found.insert(weekdayCode(for: day))
        }
        return found
    }

    /// UTC `yyyy-MM` month key shared by interest and match deterministic IDs.
    /// Single source so timezone handling cannot diverge between flows — UTC via
    /// `iso8601UTC` keeps the same instant resolving to the same month on every
    /// device, or CloudKit dedupe breaks.
    static func monthKey(for date: Date, calendar: Calendar = .iso8601UTC) -> String {
        let components = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }

    /// Single-source UTC day bucket so bucket transfers and week cycles share one timezone.
    /// Contract: `dayBucket` is UTC day via `Calendar.iso8601UTC` — not `Calendar.current`.
    /// Transfer ID ` "\(dayBucket)-\(fromRaw)-\(toRaw)"` and recordName `transfer-{profile}-{dayBucket}` are UTC-deterministic;
    /// device-local date pickers earlier in the flow must convert via `WeekMath.dayBucket`.
    /// WHY UTC: a device-local calendar splits the same instant into different days near midnight, breaking cross-device per-day dedupe.
    static func dayBucket(for date: Date) -> Int {
        Int(Calendar.iso8601UTC.startOfDay(for: date).timeIntervalSince1970 / 86400)
    }

    // WHY: Clock skew across UTC midnight can make local dayBucket differ from server dayBucket; compare server creationDate to local entry date for observability.
    static func logTransferSkewIfNeeded(localDate: Date, serverDate: Date) {
        let localBucket = dayBucket(for: localDate)
        let serverBucket = dayBucket(for: serverDate)
        if localBucket != serverBucket {
            logger.warning("Transfer dayBucket skew detected: local \(localBucket, privacy: .public) vs server \(serverBucket, privacy: .public)")
        }
    }

    // WHY: Clock skew across UTC midnight can bypass the per-day guard or mismatch transferID; transfers within 2h of midnight hint at this window.
    static func isNearUTCMidnight(_ date: Date, threshold: TimeInterval = AppConstants.Sync.nearMidnightThreshold) -> Bool {
        let start = Calendar.iso8601UTC.startOfDay(for: date)
        let seconds = date.timeIntervalSince(start)
        return seconds < threshold || seconds > 86400 - threshold
    }

    /// Today/Yesterday checks ride the shared UTC day bucket so day grouping
    /// matches the app's single timezone instead of a device-local calendar.
    static func isToday(_ date: Date) -> Bool {
        dayBucket(for: date) == dayBucket(for: Date())
    }

    static func isYesterday(_ date: Date) -> Bool {
        dayBucket(for: date) == dayBucket(for: Date()) - 1
    }

    /// WHY: Short display name owned by WeekMath so weekday rendering stays on the same UTC source as week boundaries.
    static func shortName(for weekdayCode: String) -> String {
        let codes = AppConstants.weekdayCodes
        let short = AppConstants.weekdayShort
        guard let idx = codes.firstIndex(of: weekdayCode), idx < short.count else { return weekdayCode }
        return short[idx]
    }

    /// WHY: Next weekday helper keeps due-text ordering inside WeekMath instead of duplicating code→index math in views.
    static func nextWeekdayCode(after todayCode: String, candidates: [String]) -> String? {
        let codes = AppConstants.weekdayCodes
        let todayIndex = codes.firstIndex(of: todayCode) ?? -1
        return codes.first(where: { candidates.contains($0) && (codes.firstIndex(of: $0) ?? -1) > todayIndex })
    }
}
