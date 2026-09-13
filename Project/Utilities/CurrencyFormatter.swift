//
//  CurrencyFormatter.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation
import Synchronization

/// Canonical formatter for locale-aware currency display backed by `FormatStyle.Currency`.
enum CurrencyFormatter: Sendable {
    // WHY cache: FormatStyle construction allocates; per-code bases reuse across calls.
    private static let decimalCurrencyCache = Mutex<[String: Decimal.FormatStyle.Currency]>([:])
    private static let editingNumberCache = Mutex<[String: Decimal.FormatStyle]>([:])

    static var currencyCode: String {
        Locale.current.currency?.identifier ?? "USD"
    }

    static var decimalCurrencyStyle: Decimal.FormatStyle.Currency {
        let code = currencyCode
        let base = decimalCurrencyCache.withLock { cache -> Decimal.FormatStyle.Currency in
            if let hit = cache[code] {
                return hit
            }
            let fresh = Decimal.FormatStyle.Currency(code: code)
            cache[code] = fresh
            return fresh
        }
        return base.locale(Locale.current)
    }

    private static var editingNumberStyle: Decimal.FormatStyle {
        let key = Locale.current.identifier
        return editingNumberCache.withLock { cache -> Decimal.FormatStyle in
            if let hit = cache[key] {
                return hit
            }
            let fresh = Decimal.FormatStyle.number.precision(.fractionLength(2)).grouping(.never).locale(Locale.current)
            cache[key] = fresh
            return fresh
        }
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

    /// WHY single minus: negatives ride FormatStyle so minus matches string().
    static func signed(pennies: Int64) -> String {
        if pennies < 0 {
            return string(pennies: pennies)
        }
        if pennies > 0 {
            return "+\(magnitude(pennies: pennies))"
        }
        return magnitude(pennies: pennies)
    }

    static func signed(_ pennies: Int64) -> String {
        signed(pennies: pennies)
    }

    /// WHY locale number: fields and CSV round-trip through the device decimal separator.
    static func editingString(pennies: Int64) -> String {
        (Decimal(pennies) / 100).formatted(editingNumberStyle)
    }

    static func editingString(_ pennies: Int64) -> String {
        editingString(pennies: pennies)
    }

    /// WHY locale percent: bps render with device separator so 2.5% never hardcodes a dot.
    static func percentString(bps: Int, locale: Locale = .current) -> String {
        let safe = max(0, bps)
        let whole = safe / 100
        let remainder = safe % 100
        guard remainder != 0 else { return "\(whole)%" }
        var fraction = String(format: "%02d", remainder)
        while fraction.hasSuffix("0") {
            fraction.removeLast()
        }
        let separator = locale.decimalSeparator ?? "."
        return "\(whole)\(separator)\(fraction)%"
    }

    /// WHY legacy Double: Siri/legacy rows still arrive as Double, so this preserves the string path off the penny canon.
    static func legacyDollarsToPennies(_ dollars: Double) -> Int64? {
        guard dollars.isFinite else { return nil }
        if let exact = Decimal(string: String(describing: dollars), locale: Locale(identifier: "en_US_POSIX")),
           let quantized = quantizeToPennies(exact)
        {
            return quantized
        }
        return quantizeToPennies(NSDecimalNumber(value: dollars).decimalValue)
    }

    @available(*, deprecated, renamed: "legacyDollarsToPennies")
    static func dollarsToPennies(_ dollars: Double) -> Int64? {
        legacyDollarsToPennies(dollars)
    }

    /// Locale-aware text entry parsed straight to whole pennies.
    static func pennies(from text: String, locale: Locale = .current) -> Int64? {
        guard let dollars = decimal(from: text, locale: locale) else { return nil }
        return quantizeToPennies(dollars)
    }

    /// WHY exact decimal: fields and CSV share one parser so separators never drift through Double.
    static func decimal(from text: String, locale: Locale = .current) -> Decimal? {
        var working = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !working.isEmpty else { return nil }
        var isNegative = false
        guard let unwrapped = consumeParentheses(working, isNegative: &isNegative) else { return nil }
        working = unwrapped
        let localeSymbol = locale.currencySymbol ?? ""
        let localeCode = locale.currency?.identifier ?? "USD"
        guard let firstPass = stripEdgeAffixes(working, symbol: localeSymbol, code: localeCode) else { return nil }
        working = firstPass
        guard let signed = consumeLeadingSign(working, isNegative: &isNegative) else { return nil }
        working = signed
        // WHY sign-symbol order: -$ and $- edges converge so affixes never strand.
        guard let secondPass = stripEdgeAffixes(working, symbol: localeSymbol, code: localeCode) else { return nil }
        working = secondPass
        // WHY validated gaps: space/apostrophe groupings need shape checks so 1 2.75 rejects.
        guard let gapStripped = stripValidatedGroupingGaps(working) else { return nil }
        guard !gapStripped.isEmpty else { return nil }
        guard let magnitude = magnitude(from: gapStripped, locale: locale) else { return nil }
        return isNegative ? -magnitude : magnitude
    }

    /// WHY paren negation: accounting (12.75) parses as negative without Double drift.
    private static func consumeParentheses(_ text: String, isNegative: inout Bool) -> String? {
        guard text.hasPrefix("("), text.hasSuffix(")"), text.count >= 2 else { return text }
        isNegative = true
        let inner = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? nil : inner
    }

    /// WHY affix-only: pasted symbols strip at edges so 12$75 rejects.
    private static func stripEdgeAffixes(_ text: String, symbol: String, code: String) -> String? {
        var working = stripAffixCurrencySymbols(text, symbol: symbol)
        guard !working.isEmpty else { return nil }
        if !code.isEmpty {
            working = stripCurrencyCodeToken(working, code: code)
        }
        working = working.trimmingCharacters(in: .whitespacesAndNewlines)
        return working.isEmpty ? nil : working
    }

    /// WHY sign toggle: -$ after ( ) still converges so double negatives stay positive.
    private static func consumeLeadingSign(_ text: String, isNegative: inout Bool) -> String? {
        var working = text
        if working.hasPrefix("-") || working.hasPrefix("−") {
            isNegative.toggle()
            working = String(working.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if working.hasPrefix("+") {
            working = String(working.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return working.isEmpty ? nil : working
    }

    /// WHY exact magnitude: separators normalize before Decimal so 12.75 never drifts.
    private static func magnitude(from text: String, locale: Locale) -> Decimal? {
        guard let normalized = normalizedDecimalText(text, locale: locale) else { return nil }
        guard isValidNormalizedDecimal(normalized) else { return nil }
        guard let value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        guard !value.isNaN else { return nil }
        return value
    }

    /// WHY half away: ties quantize away from zero so $1.005 never loses a penny.
    static func quantizeToPennies(_ dollars: Decimal) -> Int64? {
        guard !dollars.isNaN else { return nil }
        let scaled = dollars * 100
        guard !scaled.isNaN else { return nil }
        let isNegative = scaled < Decimal.zero
        var absCopy = isNegative ? -scaled : scaled
        var roundedAbs = Decimal()
        NSDecimalRound(&roundedAbs, &absCopy, 0, .plain)
        guard !roundedAbs.isNaN else { return nil }
        let rounded = isNegative ? -roundedAbs : roundedAbs
        let number = NSDecimalNumber(decimal: rounded)
        guard number.compare(NSDecimalNumber(value: Int64.max)) != .orderedDescending else { return nil }
        guard number.compare(NSDecimalNumber(value: Int64.min)) != .orderedAscending else { return nil }
        return number.int64Value
    }

    /// WHY last wins: US 1,234.56 and German 1.234,56 converge on any device.
    private static func normalizedDecimalText(_ text: String, locale: Locale) -> String? {
        let hasDot = text.contains(".")
        let hasComma = text.contains(",")
        if hasDot, hasComma {
            guard let decimalChar = lastSeparator(in: text) else { return nil }
            let groupingChar: Character = decimalChar == "." ? "," : "."
            guard let split = text.lastIndex(of: decimalChar) else { return nil }
            let integerPart = String(text[..<split])
            let fractionPart = String(text[text.index(after: split)...])
            guard !integerPart.isEmpty, !fractionPart.isEmpty else { return nil }
            guard fractionPart.allSatisfy(\.isWholeNumber) else { return nil }
            if integerPart.contains(groupingChar) {
                guard isGrouping(text: integerPart, separator: groupingChar) else { return nil }
                let flatInteger = integerPart.replacingOccurrences(of: String(groupingChar), with: "")
                guard !flatInteger.isEmpty, flatInteger.allSatisfy(\.isWholeNumber) else { return nil }
                return flatInteger + "." + fractionPart
            }
            guard integerPart.allSatisfy(\.isWholeNumber) else { return nil }
            return integerPart + "." + fractionPart
        } else if hasComma {
            // WHY unambiguous multi: 1,000,000 converges anywhere while single rides locale.
            if isGrouping(text: text, separator: ",") {
                if isLocaleGroupingSeparator(",", locale: locale) || text.filter({ $0 == "," }).count >= 2 {
                    return text.replacingOccurrences(of: ",", with: "")
                }
                return text.replacingOccurrences(of: ",", with: ".")
            } else {
                return text.replacingOccurrences(of: ",", with: ".")
            }
        } else if hasDot {
            // WHY unambiguous multi: 1.000.000 converges anywhere while single rides locale.
            if isGrouping(text: text, separator: ".") {
                if isLocaleGroupingSeparator(".", locale: locale) || text.filter({ $0 == "." }).count >= 2 {
                    return text.replacingOccurrences(of: ".", with: "")
                }
                return text
            } else {
                return text
            }
        } else {
            return text
        }
    }

    private static func lastSeparator(in text: String) -> Character? {
        let lastDot = text.lastIndex(of: ".")
        let lastComma = text.lastIndex(of: ",")
        switch (lastDot, lastComma) {
        case let (dot?, comma?):
            return dot > comma ? "." : ","
        case (.some, .none):
            return "."
        case (.none, .some):
            return ","
        case (.none, .none):
            return nil
        }
    }

    private static func isLocaleGroupingSeparator(_ separator: Character, locale: Locale) -> Bool {
        locale.groupingSeparator == String(separator)
    }

    /// WHY locale thousands: single grouping rides the locale separator while multi-group converges anywhere.
    static func isGrouping(text: String, separator: Character) -> Bool {
        let sep = String(separator)
        guard text.filter({ String($0) == sep }).count >= 1 else { return false }
        for ch in text where String(ch) != sep && !ch.isWholeNumber {
            return false
        }
        let parts = text.split(separator: separator, omittingEmptySubsequences: false)
        guard parts.count >= 2, !parts.contains(where: \.isEmpty) else { return false }
        guard let first = parts.first, (1 ... 3).contains(first.count) else { return false }
        for part in parts.dropFirst() where part.count != 3 {
            return false
        }
        return true
    }

    /// WHY affix edges: leading/trailing symbols strip with spaces so $ 12.75 parses.
    private static func stripAffixCurrencySymbols(_ text: String, symbol: String) -> String {
        var working = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var didStrip = true
        while didStrip {
            didStrip = false
            working = working.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !working.isEmpty else { break }
            if !symbol.isEmpty {
                if working.hasPrefix(symbol) {
                    working = String(working.dropFirst(symbol.count))
                    didStrip = true
                    continue
                }
                if working.hasSuffix(symbol) {
                    working = String(working.dropLast(symbol.count))
                    didStrip = true
                    continue
                }
            }
            if let first = working.first, first.isCurrencySymbol {
                working = String(working.dropFirst())
                didStrip = true
                continue
            }
            if let last = working.last, last.isCurrencySymbol {
                working = String(working.dropLast())
                didStrip = true
                continue
            }
        }
        return working.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// WHY shape check: gaps only group thousands so stray spaces reject.
    private static func stripValidatedGroupingGaps(_ text: String) -> String? {
        var normalized = text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
        normalized = String(normalized.map { $0.isWhitespace ? " " : $0 })
        let hasSpace = normalized.contains(" ")
        let hasApostrophe = normalized.contains("'")
        guard hasSpace || hasApostrophe else { return text }
        guard !(hasSpace && hasApostrophe) else { return nil }
        let gap: Character = hasSpace ? " " : "'"
        let lastDot = normalized.lastIndex(of: ".")
        let lastComma = normalized.lastIndex(of: ",")
        let lastSeparator: String.Index? = switch (lastDot, lastComma) {
        case let (dot?, comma?):
            dot > comma ? dot : comma
        case let (dot?, .none):
            dot
        case let (.none, comma?):
            comma
        case (.none, .none):
            nil
        }
        if let separatorIndex = lastSeparator {
            let integerPart = String(normalized[..<separatorIndex])
            let fractionPart = String(normalized[normalized.index(after: separatorIndex)...])
            guard !fractionPart.contains(gap) else { return nil }
            guard integerPart.contains(gap) else { return nil }
            guard isGrouping(text: integerPart, separator: gap) else { return nil }
            let flatInteger = integerPart.replacingOccurrences(of: String(gap), with: "")
            let decimalChar = normalized[separatorIndex]
            return flatInteger + String(decimalChar) + fractionPart
        } else {
            guard isGrouping(text: normalized, separator: gap) else { return nil }
            return normalized.replacingOccurrences(of: String(gap), with: "")
        }
    }

    /// WHY token boundary: bare codes must not strip substrings inside amounts.
    private static func stripCurrencyCodeToken(_ text: String, code: String) -> String {
        var working = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = working.lowercased()
        let codeLower = code.lowercased()
        if lower.hasPrefix(codeLower) {
            let after = working.index(working.startIndex, offsetBy: code.count, limitedBy: working.endIndex) ?? working.endIndex
            if after == working.endIndex || working[after].isWhitespace {
                working = String(working[after...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if working.lowercased().hasSuffix(codeLower), working.count >= code.count {
            let before = working.index(working.endIndex, offsetBy: -code.count)
            if before == working.startIndex || working[working.index(before: before)].isWhitespace {
                working = String(working[..<before]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return working
    }

    private static func isValidNormalizedDecimal(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        var dotCount = 0
        var digitCount = 0
        for ch in text {
            if ch == "." {
                dotCount += 1
                guard dotCount <= 1 else { return false }
            } else if ch.isWholeNumber {
                digitCount += 1
            } else {
                return false
            }
        }
        return digitCount > 0
    }

    static func presetString(_ preset: String) -> String {
        guard let pennies = pennies(from: preset) else { return string(pennies: 0) }
        return string(pennies: pennies)
    }

    static var currencySymbol: String {
        Locale.current.currencySymbol ?? ""
    }
}
