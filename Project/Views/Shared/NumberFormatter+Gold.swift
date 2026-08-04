//
//  NumberFormatter+Gold.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation

/// Single source of truth for locale-aware money display.
///
/// Every user-facing money amount — badges, balances, payouts, notifications,
/// trophy requirements — must render through this formatter so the currency
/// symbol, grouping, and decimal separators always match the user's region
/// (e.g. "$10.00", "£10.00", "10,00 €", "¥1,000"). Never hardcode a currency
/// symbol or format money with a bare String(format:).
enum CurrencyFormatter: Sendable {
    static func string(_ amount: Double) -> String {
        amount.formatted(.currency(code: Locale.current.currency?.identifier ?? "USD"))
    }

    static func magnitude(_ amount: Double) -> String {
        string(abs(amount))
    }
}
