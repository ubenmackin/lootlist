//
//  BucketKind.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import Foundation

/// The three allocation buckets every hero's earnings flow into. Buckets are a
/// closed set — money copy and FIFO goal filling branch on exactly these cases,
/// so an unknown raw value must never silently become a bucket.
enum BucketKind: String, CaseIterable, Sendable {
    case spend
    case shortTermSave
    case longTermSave

    /// Human-readable label for UI surfaces — keeps "Spend", "Short-Term Save",
    /// "Long-Term Save" in one place so views don't each define a private helper.
    var displayName: String {
        switch self {
        case .spend: "Spend"
        case .shortTermSave: "Short-Term Save"
        case .longTermSave: "Long-Term Save"
        }
    }

    /// Compact label for pill badges and condensed ledger rows.
    var shortName: String {
        switch self {
        case .spend: "Spend"
        case .shortTermSave: "Short Save"
        case .longTermSave: "Long Save"
        }
    }

    /// SF Symbol name representing each bucket.
    var iconSystemName: String {
        switch self {
        case .spend: "wallet.pass.fill"
        case .shortTermSave: "target"
        case .longTermSave: "lock.shield.fill"
        }
    }
}
