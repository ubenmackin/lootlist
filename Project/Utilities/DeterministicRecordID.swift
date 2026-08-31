//
//  DeterministicRecordID.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import CloudKit
import Foundation

/// Single-source factories for deterministic CloudKit record names used across
/// all money-movement flows. Centralizing prefixes and formatting prevents
/// cross-device dedupe divergence.
enum DeterministicRecordID {
    static func interest(profileRecordName: String, monthKey: String) -> String {
        "interest-\(profileRecordName)-\(monthKey)"
    }

    static func match(goalRecordName: String, contributionEventID: String) -> String {
        "match-\(goalRecordName)-\(contributionEventID)"
    }

    static func contribution(goalRecordName: String, sourceEventID: String) -> String {
        "contrib-\(goalRecordName)-\(sourceEventID)"
    }

    static func transfer(profileRecordName: String, transferID: String) -> String {
        "transfer-\(profileRecordName)-\(transferID)"
    }

    static func reward(completionID: String) -> String {
        "reward-\(completionID)"
    }

    static func `import`(hex: String) -> String {
        "import-\(hex)"
    }

    static func payout(periodRecordName: String) -> String {
        "payout-\(periodRecordName)"
    }

    static func realtimePayout(periodRecordName: String) -> String {
        "rt-\(periodRecordName)"
    }
}

/// Canonical deterministic identity helpers that must remain single-source.
///
/// `monthKeyUTC` is intentionally thin — the authoritative calendar math lives
/// in `WeekMath.monthKey(for:calendar:)` so timezone handling cannot diverge
/// between interest and match flows.
enum DeterministicIdentity {
    static func monthKeyUTC(for date: Date, calendar: Calendar = .iso8601UTC) -> String {
        WeekMath.monthKey(for: date, calendar: calendar)
    }
}

/// Check-before-apply idempotency guard for deterministic record names.
///
/// Every money-movement write mints a deterministic record name so
/// `CKSyncEngine` dedupes across devices. The guard is the second layer:
/// inspecting the local cache before enqueue prevents double-run creation
/// even before CloudKit reconciliation.
enum IdempotencyGuard {
    /// Returns true when `recordName` already exists in the cached ledger slice.
    static func containsDeterministicID(_ recordName: String, in entries: [LedgerEntryCache]) -> Bool {
        entries.contains(where: { $0.recordName == recordName })
    }

    /// Overload for domain `LedgerEntry` arrays (CKRecord.ID-backed).
    static func containsDeterministicID(_ recordName: String, in entries: [LedgerEntry]) -> Bool {
        entries.contains(where: { $0.id.recordName == recordName })
    }
}
