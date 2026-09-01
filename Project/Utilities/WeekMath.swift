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

    /// UTC start-of-day via `Calendar.iso8601UTC` — single-source wrapper so services never call Calendar directly for week math.
    static func startOfDay(for date: Date) -> Date {
        Calendar.iso8601UTC.startOfDay(for: date)
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

    /// UTC `yyyy-MM-dd` day key for daily-login deterministic dedupe.
    /// WHY single-source UTC: the same instant must resolve to the same
    /// `daily-{yyyy-MM-dd}` GemLedger eventKey on every device/timezone, so
    /// CloudKit `GemLedger.deterministicRecordID(eventKey:)` dedupes and
    /// `hasClaimedToday` is cross-device consistent. Mirrors `monthKey` /
    /// `DeterministicIdentity.dayKeyUTC` pattern; `WeekMath` owns the calendar
    /// math via `Calendar.iso8601UTC` so day bucket cannot diverge per device.
    /// Production always uses `Calendar.iso8601UTC`; `calendar` param exists only
    /// for deterministic test injection.
    static func dayKey(for date: Date, calendar: Calendar = .iso8601UTC) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    /// Reverse of `dayKey(for:)` — parses `yyyy-MM-dd` via the same UTC calendar
    /// so round-tripping cannot drift by timezone.
    static func date(fromDayKey dayKey: String, calendar: Calendar = .iso8601UTC) -> Date? {
        let parts = dayKey.split(separator: "-")
        // Uniform subscript access — count == 3 guarantees indices 0..<3 are valid.
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return nil }
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        return calendar.date(from: comps)
    }

    /// Calendar-aware same-day check via single-source dayKey.
    static func isSameDay(_ lhs: Date, _ rhs: Date, calendar: Calendar = .iso8601UTC) -> Bool {
        dayKey(for: lhs, calendar: calendar) == dayKey(for: rhs, calendar: calendar)
    }

    /// UTC-quantized day bucket for deterministic money-movement dedupe.
    /// Returns `Int(Calendar.iso8601UTC.startOfDay(for: date).timeIntervalSince1970 / 86400)`.
    /// WHY UTC: the same instant resolves to the same bucket on every device/timezone, so
    /// `BucketService.deterministicTransferID` / `BucketService.transfer` can dedupe via
    /// `recordName == "transfer-{profile}-{dayBucket}-{from}-{to}"` without fragmentation.
    /// WHY single capture: callers and `BucketService.transfer` must capture `Date()` once
    /// and reuse for both `dayBucket` and the ledger `date` to avoid a TOCTOU at ~00:00 UTC
    /// where successive `Date()` calls straddle midnight and yield different buckets/duplicate transfers.
    static func dayBucket(for date: Date) -> Int {
        Int(Calendar.iso8601UTC.startOfDay(for: date).timeIntervalSince1970 / 86400)
    }

    /// UTC day range for a dayBucket — half-open [start, end) via Calendar.iso8601UTC to match dayBucket(for:).
    static func utcDateRange(forDayBucket dayBucket: Int) -> Range<Date> {
        let cal = Calendar.iso8601UTC
        let epochStart = cal.startOfDay(for: Date(timeIntervalSince1970: 0))
        let start = cal.date(byAdding: .day, value: dayBucket, to: epochStart) ?? Date(timeIntervalSince1970: Double(dayBucket) * 86400)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86400)
        return start ..< end
    }

    /// Warns if local and server creation timestamps fall into different UTC day buckets.
    static func logTransferSkewIfNeeded(localDate: Date, serverDate: Date) {
        let localBucket = dayBucket(for: localDate)
        let serverBucket = dayBucket(for: serverDate)
        if localBucket != serverBucket {
            logger.warning("Transfer dayBucket skew detected: local \(localBucket, privacy: .public) vs server \(serverBucket, privacy: .public)")
        }
    }

    /// Checks if a date falls within the threshold window around UTC midnight.
    static func isNearUTCMidnight(_ date: Date, threshold: TimeInterval = AppConstants.Sync.nearMidnightThreshold) -> Bool {
        let start = Calendar.iso8601UTC.startOfDay(for: date)
        let seconds = date.timeIntervalSince(start)
        return seconds < threshold || seconds > 86400 - threshold
    }

    /// Today/Yesterday checks ride the shared UTC day bucket so day grouping
    /// matches the app's single timezone instead of a device-local calendar.
    /// `calendar` defaults to `Calendar.iso8601UTC` for production; tests may
    /// inject an explicit calendar for deterministic control.
    static func isToday(_ date: Date, calendar: Calendar = .iso8601UTC) -> Bool {
        // Fast path for the single-source UTC bucket; calendar-aware fallback via dayKey.
        if calendar == Calendar.iso8601UTC {
            return dayBucket(for: date) == dayBucket(for: Date())
        }
        return dayKey(for: date, calendar: calendar) == dayKey(for: Date(), calendar: calendar)
    }

    static func isYesterday(_ date: Date, calendar: Calendar = .iso8601UTC) -> Bool {
        if calendar == Calendar.iso8601UTC {
            return dayBucket(for: date) == dayBucket(for: Date()) - 1
        }
        // Calendar-aware: yesterday is the day before today in the same calendar.
        let cal = calendar
        guard let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date())) else { return false }
        return isSameDay(date, yesterday, calendar: cal)
    }

    static func shortName(for weekdayCode: String) -> String {
        let codes = AppConstants.weekdayCodes
        let short = AppConstants.weekdayShort
        guard let idx = codes.firstIndex(of: weekdayCode), idx < short.count else { return weekdayCode }
        return short[idx]
    }

    static func nextWeekdayCode(after todayCode: String, candidates: [String]) -> String? {
        let codes = AppConstants.weekdayCodes
        let todayIndex = codes.firstIndex(of: todayCode) ?? -1
        return codes.first(where: { candidates.contains($0) && (codes.firstIndex(of: $0) ?? -1) > todayIndex })
    }

    /// Pure half-open range containment — the single source of truth for week membership.
    /// WHY fail-closed: Quest.weekOf must be a normalized startOfWeek (UTC midnight).
    /// A fallback (e.g. Calendar granularity check) would silently mask a storage bug
    /// where weekOf was saved non-normalized; keep this pure and assert/normalize on write
    /// (QuestService assign paths via WeekMath.startOfWeek).
    static func isQuestInCurrentWeek(_ questWeekOf: Date, range: Range<Date>) -> Bool {
        // Fail-closed: surface non-normalized storage bugs in DEBUG instead of masking with fallback.
        assert(Calendar.iso8601UTC.startOfDay(for: questWeekOf) == questWeekOf, "Quest.weekOf must be normalized to WeekMath.startOfWeek (UTC midnight)")
        assert(Calendar.iso8601UTC.startOfDay(for: range.lowerBound) == range.lowerBound, "WeekMath range lowerBound must be normalized startOfWeek")
        return range.contains(questWeekOf)
    }
}
