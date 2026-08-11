//
//  CalendarScope.swift
//  LootList
//
//  Created by Ben Mackin on 8/10/26.
//

import Foundation

/// Scopes a calendar-bound filter (this week, this month, this quarter, or all
/// time) used by segmented filter controls and date-range sublabels across
/// list views.
enum CalendarScope: String, CaseIterable, Identifiable, Codable {
    case thisWeek
    case thisMonth
    case thisQuarter
    case allTime

    var id: String {
        rawValue
    }

    /// User-facing label for the segmented picker and accessibility descriptions.
    var displayLabel: String {
        switch self {
        case .thisWeek: "Week"
        case .thisMonth: "Month"
        case .thisQuarter: "Quarter"
        case .allTime: "All Time"
        }
    }

    /// Empty-state copy bound to list views when the scoped result set is empty.
    var emptyStateCopy: String {
        switch self {
        case .thisWeek: "No entries this week."
        case .thisMonth: "No entries this month."
        case .thisQuarter: "No entries this quarter."
        case .allTime: "No entries yet."
        }
    }

    /// Inclusive bounds of the scope for the current date, used to format
    /// sublabels and to test membership via `contains(_:)`. `allTime` spans
    /// from the distant past to now so it contains every date.
    ///
    /// Uses the `WeekMath` default payout day (`.sunday`) so the scope remains
    /// usable where the family's payout day is not known.
    var dateRange: ClosedRange<Date> {
        dateRange(payoutDay: .sunday)
    }

    /// Inclusive bounds of the scope for the current date, anchored on the
    /// given payout day for `.thisWeek`. The `.thisWeek` range starts at the
    /// family's payout-cycle start (`WeekMath.startOfWeek(for:payoutDay:)`)
    /// instead of a hard-coded calendar week, so custom-payday families keep
    /// the current cycle's early entries in scope. `.month`, `.quarter`, and
    /// `.allTime` remain strictly calendar-based and ignore the payout day.
    func dateRange(payoutDay: PayoutDay) -> ClosedRange<Date> {
        switch self {
        case .thisWeek:
            let start = WeekMath.startOfWeek(for: Date(), payoutDay: payoutDay)
            let end = start.addingTimeInterval(TimeInterval(AppConstants.Time.secondsInWeek - 1))
            return start ... end
        case .thisMonth:
            return monthOrQuarterRange(.month)
        case .thisQuarter:
            return monthOrQuarterRange(.quarter)
        case .allTime:
            return Date.distantPast ... Date()
        }
    }

    /// Medium-style formatted bounds joined by an en dash, e.g.
    /// "Aug 1, 2026 – Aug 31, 2026". Returns an empty string for `allTime`,
    /// where a bounded sublabel is not meaningful.
    ///
    /// Uses the `WeekMath` default payout day (`.sunday`) so the sublabel
    /// stays correct where the family's payout day is not known.
    var dateRangeSublabel: String {
        dateRangeSublabel(payoutDay: .sunday)
    }

    /// Medium-style formatted bounds joined by an en dash, e.g.
    /// "Aug 1, 2026 – Aug 31, 2026". The `.thisWeek` bounds are anchored on
    /// the given payout day so the label matches the scoped rows. Returns an
    /// empty string for `allTime`, where a bounded sublabel is not meaningful.
    func dateRangeSublabel(payoutDay: PayoutDay) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        switch self {
        case .allTime:
            return ""
        case .thisWeek, .thisMonth, .thisQuarter:
            let range = dateRange(payoutDay: payoutDay)
            return "\(formatter.string(from: range.lowerBound)) – \(formatter.string(from: range.upperBound))"
        }
    }

    /// Returns `true` when `date` falls within the scope's current bounds.
    /// `allTime` always returns `true`.
    ///
    /// Uses the `WeekMath` default payout day (`.sunday`) so the check stays
    /// correct where the family's payout day is not known.
    func contains(_ date: Date) -> Bool {
        contains(date, payoutDay: .sunday)
    }

    /// Returns `true` when `date` falls within the scope's current bounds.
    /// The `.thisWeek` bounds are anchored on the given payout day so a
    /// custom-payday family's early-cycle entries are not dropped. `.month`,
    /// `.quarter`, and `.allTime` ignore the payout day. `allTime` always
    /// returns `true`.
    func contains(_ date: Date, payoutDay: PayoutDay) -> Bool {
        switch self {
        case .allTime:
            true
        case .thisWeek, .thisMonth, .thisQuarter:
            dateRange(payoutDay: payoutDay).contains(date)
        }
    }

    /// Shared helper for the `.month` and `.quarter` calendar intervals.
    private func monthOrQuarterRange(_ component: Calendar.Component) -> ClosedRange<Date> {
        let cal = Calendar.iso8601UTC
        guard let interval = cal.dateInterval(of: component, for: Date()) else {
            let now = Date()
            return now ... now
        }
        let end = interval.end.addingTimeInterval(-1)
        return interval.start ... end
    }
}
