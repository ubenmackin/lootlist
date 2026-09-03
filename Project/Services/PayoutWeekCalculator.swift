//
//  PayoutWeekCalculator.swift
//  LootList
//
//  Created by Ben Mackin on 9/2/26.
//

import Foundation

/// Single-source calculator for payout-week derivation shared by
/// `PayoutDetailSheet` and `PayoutDetailContent`.
///
/// Why centralised: both views previously duplicated identical
/// `weekBucketEntries` filtering (`WeekMath.weekRange`), `goalContributions`
/// mapping, and `BucketKind` totals. `WeekMath` owns week boundaries per
/// ARCHITECTURE.md — this type owns interpreting those buckets for payout
/// display so history and sheet cannot diverge.
enum PayoutWeekCalculator {
    /// Filters `ledgerEntries` to the half-open week `[weekOf, weekOf+7d)` that
    /// contains `period.weekOf`. Delegates boundary math exclusively to `WeekMath`.
    static func weekBucketEntries(
        for period: AllowancePeriodCache,
        from ledgerEntries: [LedgerEntryCache]
    ) -> [LedgerEntryCache] {
        let range = WeekMath.weekRange(starting: period.weekOf)
        return ledgerEntries.filter { range.contains($0.date) }
    }

    /// Goal contributions derived from deterministic `contrib-*` records within
    /// the already-filtered `weekBucketEntries`.
    static func goalContributions(
        for goals: [GoalCache],
        in weekBucketEntries: [LedgerEntryCache]
    ) -> [(goal: GoalCache, amount: Double)] {
        goals.compactMap { goal in
            let total = GoalProgressCalculator.contributionAmount(for: goal, in: weekBucketEntries)
            return total > 0 ? (goal, total) : nil
        }
    }

    /// Convenience that derives `weekBucketEntries` then maps goals in one call.
    static func goalContributions(
        for period: AllowancePeriodCache,
        ledgerEntries: [LedgerEntryCache],
        goals: [GoalCache]
    ) -> [(goal: GoalCache, amount: Double)] {
        let entries = weekBucketEntries(for: period, from: ledgerEntries)
        return goalContributions(for: goals, in: entries)
    }

    /// Total amount for a single `BucketKind` within the week's entries.
    /// An entry contributes when `bucketKind == kind` or `toBucket == kind`,
    /// mirroring the single-ledger-row transfer attribution.
    static func bucketTotal(
        for kind: BucketKind,
        in weekBucketEntries: [LedgerEntryCache]
    ) -> Double {
        let filtered = weekBucketEntries.filter { entry in
            let bucketMatches = entry.bucketKind == kind.rawValue
            let transferMatches = entry.toBucket == kind.rawValue
            return bucketMatches || transferMatches
        }
        return filtered.reduce(0.0) { partial, entry in
            let amount = entry.amount
            return partial + amount
        }
    }

    /// Totals for all buckets that have non-zero activity, keyed by kind.
    static func totalsByBucket(
        in weekBucketEntries: [LedgerEntryCache]
    ) -> [BucketKind: Double] {
        var totals: [BucketKind: Double] = [:]
        for kind in BucketKind.allCases {
            let total = bucketTotal(for: kind, in: weekBucketEntries)
            if total != 0 {
                totals[kind] = total
            }
        }
        return totals
    }

    /// Week-filtered ledger entries for a profile's payout week.
    /// WHY: centralises WeekMath.weekRange so views never compute week boundaries directly.
    static func weekLedgerEntries(
        for period: AllowancePeriodCache,
        from ledgers: [LedgerEntryCache]
    ) -> [LedgerEntryCache] {
        weekBucketEntries(for: period, from: ledgers)
            .filter { $0.profileRecordName == period.profileRecordName }
    }
}
