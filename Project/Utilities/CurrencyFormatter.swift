//
//  CurrencyFormatter.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation

/// Canonical formatter for locale-aware currency display.
enum CurrencyFormatter: Sendable {
    static func string(_ amount: Double) -> String {
        amount.formatted(.currency(code: Locale.current.currency?.identifier ?? "USD"))
    }

    static func magnitude(_ amount: Double) -> String {
        string(abs(amount))
    }

    // WHY: Preset pills share one DRY currency path so locale changes stay single-point.
    static func presetString(_ preset: String) -> String {
        string(Double(preset) ?? 0)
    }

    // WHY: Editing fields need plain decimals without currency symbol, but still centralize via CurrencyFormatter.
    static func editingString(_ amount: Double) -> String {
        String(format: "%.2f", amount)
    }

    // WHY: Expose symbol without hardcoding "$" so views never embed a literal.
    static var currencySymbol: String {
        Locale.current.currencySymbol ?? ""
    }

    /// Locale-aware decimal parsing — single-source for all amount fields so
    /// comma decimals (e.g. "1,99") work in every locale.
    static func decimalDouble(from text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = Locale.current
        formatter.numberStyle = .decimal
        if let number = formatter.number(from: trimmed) {
            let value = number.doubleValue
            guard value.isFinite else { return nil }
            return value
        }
        // Fallback for pasted values with alternate separator.
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite else { return nil }
        return value
    }
}
