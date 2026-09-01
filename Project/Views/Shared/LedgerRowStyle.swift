//
//  LedgerRowStyle.swift
//  LootList
//
//  Created by Ben Mackin on 8/8/26.
//

import Foundation
import SwiftUI

/// Shared visual identity for ledger entry rows (source tile / label / date),
/// used by both the treasury ledger and the per-hero ledger.
enum LedgerRowStyle {
    /// WHY static formatter: per-cell DateFormatter alloc caused scroll jank; reuse single instance confined to MainActor.
    @MainActor private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// Resolves the SF Symbol and tint for a ledger entry's source.
    /// Unknown sources fall back to the caller-supplied tint so each ledger
    /// screen keeps its own neutral color for unrecognized sources.
    static func sourceIcon(for source: String, fallbackTint: Color) -> (name: String, color: Color) {
        switch source {
        case "quest": ("checkmark.seal.fill", Color(DesignSystemConstants.Colors.primaryGreen))
        case "deposit": ("plus.circle.fill", .gold)
        case "withdrawal": ("minus.circle.fill", Color(DesignSystemConstants.Colors.pendingAmber))
        case "manual": ("arrow.down.circle.fill", Color(DesignSystemConstants.Colors.dangerRed))
        default: ("banknote", fallbackTint)
        }
    }

    /// User-facing name for a ledger entry's source; unknown sources render
    /// the raw source value capitalized.
    static func sourceLabel(for source: String) -> String {
        switch source {
        case "quest": "Quest"
        case "deposit": "Deposit"
        case "withdrawal": "Withdrawal"
        case "manual": "Spent"
        default: source.capitalized
        }
    }

    /// Shared medium-date + short-time rendering for ledger timestamps.
    @MainActor static func dateText(for date: Date) -> String {
        // WHY static formatter: reused MainActor-confined formatter avoids per-cell alloc during scrolling.
        dateFormatter.string(from: date)
    }
}
