//
//  LedgerSource.swift
//  LootList
//
//  Created by Ben Mackin on 8/28/26.
//

import Foundation

/// Strongly-typed tag for `LedgerEntry.source` persistence.
/// Raw string storage is unchanged for CloudKit compatibility — this enum
/// provides exhaustive switching over the known source values.
enum LedgerSource: String, Codable, Sendable, CaseIterable {
    case quest
    case transfer
    case `import`
    case goal
    case interest
    case match
    case manual
    case purchase
    case deposit
    case withdrawal

    /// WHY single truth: import-prefixed rows decode to `.import` everywhere so ledger grouping never drifts.
    static func decode(_ raw: String) -> LedgerSource? {
        if raw.hasPrefix(LedgerSource.import.rawValue) {
            return .import
        }
        return LedgerSource(rawValue: raw)
    }
}
