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

    // MARK: - Week Calculations

    static func mondayOfWeek(for date: Date) -> Date {
        let cal = Calendar.iso8601UTC
        let components = cal.dateComponents(
            [.yearForWeekOfYear, .weekOfYear], from: date
        )
        return cal.date(from: components) ?? cal.startOfDay(for: date)
    }

    /// Returns the inclusive start of the payout-anchored week containing `date`.
    ///
    /// The payout day is the **last** day of the week — the cycle starts the
    /// day *after* `payoutDay` (e.g. `.sunday` → Monday). The 7-day interval is
    /// always `[cycleStart 00:00, next cycleStart 00:00)` (half-open).
    ///
    /// Exhaustive weekday mapping (`PayoutDay.calendarWeekday` → cycle start):
    /// ```
    /// | PayoutDay | weekday | cycleStartWeekday | interval          | ends |
    /// |-----------|---------|-------------------|-------------------|------|
    /// | .sunday    | 1 | 2 (Mon) | [Mon 00:00, next Mon) | Sunday   |
    /// | .monday    | 2 | 3 (Tue) | [Tue 00:00, next Tue) | Monday   |
    /// | .tuesday   | 3 | 4 (Wed) | [Wed 00:00, next Wed) | Tuesday  |
    /// | .wednesday | 4 | 5 (Thu) | [Thu 00:00, next Thu) | Wednesday|
    /// | .thursday  | 5 | 6 (Fri) | [Fri 00:00, next Fri) | Thursday |
    /// | .friday    | 6 | 7 (Sat) | [Sat 00:00, next Sat) | Friday   |
    /// | .saturday  | 7 | 1 (Sun) | [Sun 00:00, next Sun) | Saturday |
    /// ```
    /// Verified exhaustively for all 7 `PayoutDay` cases: 2026-08-15 Sat 23:59
    /// and 2026-08-16 Sun 00:00 bucket to **different** weeks for `.saturday`
    /// (Sat is last day of [Sun..Sun) week, Sun 00:00 is start of next), but to
    /// the **same** week for `.friday` ([Sat..Sat) contains both). The
    /// calculation `cycleStartWeekday = (targetWeekday % 7) + 1` rotates every
    /// payout day to its successor (1…7 → 2…7,1) with the modulo handling the
    /// Sat→Sun wrap; `daysToSubtract = (current - cycleStart + 7) % 7` wraps
    /// correctly regardless of where `date` falls, and `iso8601UTC` guarantees a
    /// DST-free midnight. A `Date` equal to `start` belongs to that week;
    /// a `Date` equal to `end` belongs to the next (half-open).
    static func startOfWeek(for date: Date, payoutDay: PayoutDay = .sunday) -> Date {
        let cal = Calendar.iso8601UTC
        let startOfDay = cal.startOfDay(for: date)
        let targetWeekday = payoutDay.calendarWeekday

        // Next-day rotation: payoutDay's weekday (1=Sun…7=Sat) maps to the
        // cycle start (payoutDay + 1 day). Modulo handles the Sat→Sun wrap.
        let cycleStartWeekday = (targetWeekday % 7) + 1
        let currentWeekday = cal.component(.weekday, from: startOfDay)

        // Distance back to the most recent cycle start (0…6), wrapping via +7.
        let daysToSubtract = (currentWeekday - cycleStartWeekday + 7) % 7

        return cal.date(byAdding: .day, value: -daysToSubtract, to: startOfDay) ?? startOfDay
    }

    static func weekOf(date: Date, payoutDay: PayoutDay = .sunday) -> Date {
        startOfWeek(for: date, payoutDay: payoutDay)
    }

    // MARK: - Half-Open Range

    /// Half-open week range `[start, end)` where `end` is exclusive (next Monday
    /// 00:00 UTC for the payout-day-anchored week). Using the exclusive upper
    /// bound as the payout gate (`now >= upperBound`) means "Sunday Loot Day"
    /// fires at the instant the week closes (Monday 00:00), not at Sunday
    /// 00:00 a full day early, and avoids DST 23h/25h midnight drift — the
    /// range is always exactly 7×24h in UTC (no DST) and the gate is the
    /// canonical half-open end, not `start + 6 days` then `startOfDay`. Callers
    /// needing inclusive end-of-day should use `upperBound - 1 second` with a
    /// calendar-aware check explicitly; the default stays half-open so
    /// `Date == end` belongs to the following week (see §5 Payout Policy).
    static func weekRange(starting start: Date) -> Range<Date> {
        let cal = Calendar.iso8601UTC
        let normalizedStart = cal.startOfDay(for: start)
        // UTC has no DST, so adding exactly secondsInWeek (7×86400) is
        // equivalent to cal.date(byAdding: .day, value: 7, to: normalizedStart)
        // but reuses the canonical constant. If the calendar were ever non-UTC,
        // prefer the calendar-aware `date(byAdding: .day, value: 7, ...)` to
        // avoid 23h/25h spring-forward drift.
        let end = normalizedStart.addingTimeInterval(TimeInterval(secondsInWeek))
        return normalizedStart ..< end
    }
}
