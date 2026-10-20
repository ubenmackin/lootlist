//
//  LedgerRowStyle.swift
//  LootList
//
//  Created by Ben Mackin on 8/8/26.
//

import Foundation

/// Shared date rendering for grouped ledger cards.
enum LedgerRowStyle {
    /// WHY Sendable styles: per-cell labels reuse value types without shared mutable formatter.
    private static let currentYearStyle: Date.FormatStyle = .dateTime.month(.abbreviated).day().hour().minute()
    private static let priorYearStyle: Date.FormatStyle = .dateTime.month(.abbreviated).day().year().hour().minute()

    /// WHY compact header: short type titles pair with a short timestamp so grouped cards scan in one line.
    static func shortDateText(for date: Date) -> String {
        // WHY single now: one sample keeps the year check atomic across midnight.
        let now = Date()
        let calendar = Calendar.current
        let isCurrentYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        if isCurrentYear {
            return date.formatted(currentYearStyle)
        }
        return date.formatted(priorYearStyle)
    }
}
