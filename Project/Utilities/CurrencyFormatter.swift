//
//  CurrencyFormatter.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation

/// Canonical formatter for locale-aware currency display.
///
/// WHY: Uses FormatStyle.Currency backed by Locale.current.currency so the
/// formatter is cached (no per-call NumberFormatter allocation for 20+ call
/// sites) and composes with SwiftUI Text(value, format: .currency(code:)).
enum CurrencyFormatter: Sendable {
    // WHY: Locale-aware currency code drives FormatStyle; fallback keeps formatting stable.
    static var currencyCode: String {
        Locale.current.currency?.identifier ?? "USD"
    }

    // WHY: Cached currency FormatStyle avoids per-call NumberFormatter allocation
    // and composes with SwiftUI Text(value, format: .currency(code:)).
    static var currencyStyle: FloatingPointFormatStyle<Double>.Currency {
        FloatingPointFormatStyle<Double>.Currency(code: currencyCode).locale(Locale.current)
    }

    static var decimalCurrencyStyle: Decimal.FormatStyle.Currency {
        Decimal.FormatStyle.Currency(code: currencyCode).locale(Locale.current)
    }

    /// Compatibility shim — existing 20+ call sites keep calling string(_:)
    /// while behavior is now backed by the cached FormatStyle.
    static func string(_ amount: Double) -> String {
        amount.formatted(currencyStyle)
    }

    static func string(_ amount: Decimal) -> String {
        amount.formatted(decimalCurrencyStyle)
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
    ///
    /// WHY: Shared FormatStyle parse avoids per-call NumberFormatter allocation.
    static func decimalDouble(from text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Shared FormatStyle parse — no per-call NumberFormatter allocation.
        let numberStyle = FloatingPointFormatStyle<Double>.number.locale(Locale.current)
        do {
            let value = try numberStyle.parseStrategy.parse(trimmed)
            guard value.isFinite else { return nil }
            return value
        } catch {
            // Expected for pasted values with alternate locale decimal separator — continue to fallback below
        }
        // Fallback for pasted values with alternate separator.
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite else { return nil }
        return value
    }
}
