//
//  LedgerRowStyle.swift
//  LootList
//
//  Created by Ben Mackin on 8/8/26.
//

import SwiftUI

/// Shared date rendering for grouped ledger cards.
enum LedgerRowStyle {
    /// WHY single owner: every ledger row maps sources through one helper so icons never drift.
    static func rowIcon(for source: LedgerSource?) -> (systemName: String, color: Color) {
        switch source {
        case .quest:
            (systemName: "checkmark", color: Color(DesignSystemConstants.Colors.primaryGreen))
        case .manual:
            (systemName: "cart", color: Color(DesignSystemConstants.Colors.pendingAmber))
        case .deposit:
            (systemName: "plus", color: Color(DesignSystemConstants.Colors.primaryGreen))
        case .withdrawal:
            (systemName: "minus", color: Color(DesignSystemConstants.Colors.pendingAmber))
        case .transfer:
            (systemName: "arrow.left.arrow.right", color: Color(DesignSystemConstants.Colors.accentBlue))
        case .interest:
            (systemName: "percent", color: Color(DesignSystemConstants.Colors.accentBlue))
        case .match:
            (systemName: "heart", color: Color(DesignSystemConstants.Colors.matchPink))
        case .purchase:
            (systemName: "bag", color: Color.primary)
        case .import:
            (systemName: "doc", color: Color.secondary)
        case .goal:
            (systemName: "target", color: Color.secondary)
        case .none:
            (systemName: "doc", color: Color.secondary)
        }
    }

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
