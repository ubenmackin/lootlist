//
//  CurrencyFormatterPenniesTests.swift
//  LootList
//
//  Created by Ben Mackin on 9/11/26.
//

import Foundation
@testable import LootList
import Testing

struct CurrencyFormatterPenniesTests {
    @Test
    func `dot decimal parses to exact pennies`() {
        #expect(CurrencyFormatter.pennies(from: "12.75") == 1275)
    }

    @Test
    func `comma decimal parses to exact pennies`() {
        // WHY locale parity: pasted European decimals converge without device switching.
        #expect(CurrencyFormatter.pennies(from: "12,75") == 1275)
    }

    @Test
    func `small amounts quantize without drift`() {
        #expect(CurrencyFormatter.pennies(from: "2.50") == 250)
        #expect(CurrencyFormatter.pennies(from: "0.01") == 1)
    }

    @Test
    func `groupings converge regardless of separator`() {
        #expect(CurrencyFormatter.pennies(from: "1,234.56") == 123_456)
        #expect(CurrencyFormatter.pennies(from: "1.234,56") == 123_456)
    }

    @Test
    func `single comma grouping follows the locale separator`() {
        // WHY locale pin: single separators ride the locale grouping separator.
        #expect(CurrencyFormatter.pennies(from: "1,234", locale: Locale(identifier: "en_US")) == 123_400)
        #expect(CurrencyFormatter.pennies(from: "1,234", locale: Locale(identifier: "de_DE")) == 123)
    }

    @Test
    func `single dot follows the locale separator`() {
        // WHY locale pin: single separators ride the locale grouping separator.
        #expect(CurrencyFormatter.pennies(from: "1.234", locale: Locale(identifier: "en_US")) == 123)
        #expect(CurrencyFormatter.pennies(from: "1.234", locale: Locale(identifier: "de_DE")) == 123_400)
    }

    @Test
    func `unambiguous multi-group converges across locales`() {
        // WHY cross-locale paste: multi-group thousands converge without device switching.
        for locale in [Locale(identifier: "en_US"), Locale(identifier: "de_DE")] {
            #expect(CurrencyFormatter.pennies(from: "1,000,000", locale: locale) == 100_000_000)
            #expect(CurrencyFormatter.pennies(from: "1.000.000", locale: locale) == 100_000_000)
        }
    }

    @Test
    func `space and apostrophe gaps need grouping shape`() {
        // WHY shape check: stray gaps reject instead of merging digits.
        #expect(CurrencyFormatter.pennies(from: "1 2.75") == nil)
        #expect(CurrencyFormatter.pennies(from: "1'2.75") == nil)
        #expect(CurrencyFormatter.pennies(from: "1 234.56") == 123_456)
        #expect(CurrencyFormatter.pennies(from: "1'234.56") == 123_456)
    }

    @Test
    func `embedded currency symbols reject`() {
        // WHY affix-only: symbols strip at edges so embedded symbols reject.
        #expect(CurrencyFormatter.pennies(from: "12$75") == nil)
        #expect(CurrencyFormatter.pennies(from: "$12.75") == 1275)
    }

    @Test
    func `malformed separators reject instead of guessing`() {
        #expect(CurrencyFormatter.pennies(from: "1,2,3.45") == nil)
        #expect(CurrencyFormatter.pennies(from: "1.2,3,45") == nil)
    }

    @Test
    func `currency symbol prefixes parse`() {
        #expect(CurrencyFormatter.pennies(from: "$12.75") == 1275)
        #expect(CurrencyFormatter.pennies(from: " $1,234.56 ") == 123_456)
    }

    @Test
    func `parenthesized and signed negatives parse`() {
        #expect(CurrencyFormatter.pennies(from: "(12.75)") == -1275)
        #expect(CurrencyFormatter.pennies(from: "($12.75)") == -1275)
        #expect(CurrencyFormatter.pennies(from: "-12.75") == -1275)
        #expect(CurrencyFormatter.pennies(from: "+12.75") == 1275)
    }

    @Test
    func `ties round half up away from zero`() {
        // WHY half-up: Decimal keeps the tie exact so it rounds up.
        #expect(CurrencyFormatter.pennies(from: "1.005") == 101)
        #expect(CurrencyFormatter.pennies(from: "-1.005") == -101)
    }

    @Test
    func `empty and invalid inputs return nil`() {
        #expect(CurrencyFormatter.pennies(from: "") == nil)
        #expect(CurrencyFormatter.pennies(from: "   ") == nil)
        #expect(CurrencyFormatter.pennies(from: "abc") == nil)
        #expect(CurrencyFormatter.pennies(from: "$n/a") == nil)
        #expect(CurrencyFormatter.pennies(from: "$") == nil)
    }

    @Test
    func `import parser shares the formatter result`() {
        // WHY single source: CSV amounts ride the same parser as fields.
        #expect(LedgerCSVParser.parseAmount("12.75") == CurrencyFormatter.pennies(from: "12.75"))
        #expect(LedgerCSVParser.parseAmount("$12.75") == 1275)
    }
}
