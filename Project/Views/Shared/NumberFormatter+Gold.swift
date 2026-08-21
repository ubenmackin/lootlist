//
//  NumberFormatter+Gold.swift
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
}
