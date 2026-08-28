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

    /// Inclusive bounds of the scope for the current date, used to format sublabels and to test membership
    /// via `contains(_:)`.
    var dateRange: ClosedRange<Date> {
        dateRange(payoutDay: .sunday)
    }

    /// Inclusive bounds of the scope for the current date, anchored on the given payout day for
    /// `.thisWeek`.
    func dateRange(payoutDay: PayoutDay) -> ClosedRange<Date> {
        switch self {
        case .thisWeek:
            let start = WeekMath.startOfWeek(for: Date(), payoutDay: payoutDay)
            let halfOpen = WeekMath.weekRange(starting: start)
            return halfOpen.lowerBound ... halfOpen.upperBound.addingTimeInterval(-1)
        case .thisMonth:
            return monthOrQuarterRange(.month)
        case .thisQuarter:
            return monthOrQuarterRange(.quarter)
        case .allTime:
            return Date.distantPast ... Date()
        }
    }

    /// Medium-style formatted bounds joined by an en dash, e.g. "Aug 1, 2026 – Aug 31, 2026".
    var dateRangeSublabel: String {
        dateRangeSublabel(payoutDay: .sunday)
    }

    /// Medium-style formatted bounds joined by an en dash, e.g. "Aug 1, 2026 – Aug 31, 2026".
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

    /// Returns true when date falls within current bounds using default payout day.
    func contains(_ date: Date) -> Bool {
        contains(date, payoutDay: .sunday)
    }

    /// Returns true when date falls within scope bounds using the given payout day.
    func contains(_ date: Date, payoutDay: PayoutDay) -> Bool {
        switch self {
        case .allTime:
            return true
        case .thisWeek:
            let start = WeekMath.startOfWeek(for: Date(), payoutDay: payoutDay)
            return WeekMath.weekRange(starting: start).contains(date)
        case .thisMonth:
            return halfOpenMonthOrQuarterRange(.month).contains(date)
        case .thisQuarter:
            return halfOpenMonthOrQuarterRange(.quarter).contains(date)
        }
    }

    /// Half-open interval for `.month` / `.quarter` derived directly from
    /// `Calendar.dateInterval` (`interval.end` is exclusive).
    private func halfOpenMonthOrQuarterRange(_ component: Calendar.Component) -> Range<Date> {
        let cal = Calendar.iso8601UTC
        guard let interval = cal.dateInterval(of: component, for: Date()) else {
            let now = Date()
            return now ..< now.addingTimeInterval(1)
        }
        return interval.start ..< interval.end
    }

    /// Closed display range for `.month` / `.quarter`. The half-open `interval.end`
    /// is exclusive, but sublabels need an inclusive upper bound for formatting, so
    /// the closed bound is `halfOpen.upperBound - 1s` and documented here intentionally.
    private func monthOrQuarterRange(_ component: Calendar.Component) -> ClosedRange<Date> {
        let halfOpen = halfOpenMonthOrQuarterRange(component)
        return halfOpen.lowerBound ... halfOpen.upperBound.addingTimeInterval(-1)
    }
}
