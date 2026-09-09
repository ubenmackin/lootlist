//
//  CurrencyFormatter.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation
import os

/// Canonical formatter for locale-aware currency display backed by `FormatStyle.Currency`.
enum CurrencyFormatter: Sendable {
    private static let logger = Logger(category: "CurrencyFormatter")

    static var currencyCode: String {
        Locale.current.currency?.identifier ?? "USD"
    }

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

    /// Canonical pennies entry point — all money renders through here so
    /// integer pennies never drift through Double.
    static func string(pennies: Int64) -> String {
        string(Decimal(pennies) / 100)
    }

    /// WHY unlabeled Int64: @Query caches now carry pennies, so existing
    /// string(_:) call sites resolve to integer math without per-view edits.
    static func string(_ pennies: Int64) -> String {
        string(pennies: pennies)
    }

    static func string(_ pennies: Int) -> String {
        string(pennies: Int64(pennies))
    }

    static func magnitude(pennies: Int64) -> String {
        string(pennies: abs(pennies))
    }

    static func magnitude(_ pennies: Int64) -> String {
        magnitude(pennies: pennies)
    }

    static func signed(pennies: Int64) -> String {
        let body = magnitude(pennies: pennies)
        if pennies < 0 {
            return "−\(body)"
        }
        if pennies > 0 {
            return "+\(body)"
        }
        return body
    }

    static func signed(_ pennies: Int64) -> String {
        signed(pennies: pennies)
    }

    static func editingString(pennies: Int64) -> String {
        String(format: "%.2f", Double(pennies) / 100.0)
    }

    static func editingString(_ pennies: Int64) -> String {
        editingString(pennies: pennies)
    }

    /// WHY round half up: dollar inputs quantize to whole pennies away from
    /// zero on ties so $1.005 never loses a penny to banker's rounding.
    static func dollarsToPennies(_ dollars: Double) -> Int64 {
        guard dollars.isFinite else { return 0 }
        return Int64((dollars * 100).rounded(.toNearestOrAwayFromZero))
    }

    /// Locale-aware text entry parsed straight to whole pennies.
    static func pennies(from text: String) -> Int64? {
        guard let dollars = decimalDouble(from: text) else { return nil }
        return dollarsToPennies(dollars)
    }

    static func magnitude(_ amount: Double) -> String {
        string(abs(amount))
    }

    static func presetString(_ preset: String) -> String {
        string(Double(preset) ?? 0)
    }

    static func editingString(_ amount: Double) -> String {
        String(format: "%.2f", amount)
    }

    static var currencySymbol: String {
        Locale.current.currencySymbol ?? ""
    }

    /// Locale-aware decimal parsing — single-source for all amount fields so
    /// comma decimals (e.g. "1,99") work in every locale.
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
            // Expected for pasted values with alternate locale decimal separator — proceed to fallback normalization.
            logger.debug("FormatStyle parse failed for '\(trimmed, privacy: .private)': \(error, privacy: .private); attempting normalized fallback")
        }
        // Fallback for pasted values with alternate separator.
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite else { return nil }
        return value
    }
}
