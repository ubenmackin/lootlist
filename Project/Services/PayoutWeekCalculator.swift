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
/// display so history and sheet cannot diverge. Profile-scoping is canonical
/// here: every week/payout lookup re-applies `period.profileRecordName`, so
/// family-wide arrays stay fail-closed and caller pre-filtering is an
/// idempotent fast path, not a second source of truth.
enum PayoutWeekCalculator {
    /// Filters `ledgerEntries` to the half-open week `[weekOf, weekOf+7d)` that
    /// contains `period.weekOf` for `period.profileRecordName`. Delegates boundary math exclusively to `WeekMath`.
    /// Profile-scoping is canonical: callers may pre-filter by profile, but this filter remains the single source so week math alone never mixes heroes.
    static func weekBucketEntries(
        for period: AllowancePeriodCache,
        from ledgerEntries: [LedgerEntryCache]
    ) -> [LedgerEntryCache] {
        let range = WeekMath.weekRange(starting: period.weekOf)
        // WHY profile scope: callers pass family-wide arrays, so week math alone would mix heroes.
        return ledgerEntries.filter { $0.profileRecordName == period.profileRecordName && range.contains($0.date) }
    }

    /// Goal contributions derived from deterministic `contrib-*` records within
    /// the already-filtered `weekBucketEntries`.
    static func goalContributions(
        for goals: [GoalCache],
        in weekBucketEntries: [LedgerEntryCache]
    ) -> [(goal: GoalCache, amount: Int64)] {
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
    ) -> [(goal: GoalCache, amount: Int64)] {
        let entries = weekBucketEntries(for: period, from: ledgerEntries)
        return goalContributions(for: goals, in: entries)
    }

    /// Total amount for a single `BucketKind` within the week's entries.
    /// WHY single-source: routes via `BucketService.applyBucketAttribution` so transfers debit `fromBucket` and goal markers stay excluded, matching hub/dashboard.
    static func bucketTotal(
        for kind: BucketKind,
        in weekBucketEntries: [LedgerEntryCache]
    ) -> Int64 {
        weekBalances(in: weekBucketEntries)[kind, default: 0]
    }

    /// Totals for all buckets that have non-zero activity, keyed by kind.
    static func totalsByBucket(
        in weekBucketEntries: [LedgerEntryCache]
    ) -> [BucketKind: Int64] {
        weekBalances(in: weekBucketEntries).filter { $0.value != 0 }
    }

    /// WHY single-source: counted money plus transfer moves ride one attribution so week sheet matches hub balances.
    private static func weekBalances(
        in weekBucketEntries: [LedgerEntryCache]
    ) -> [BucketKind: Int64] {
        var balances: [BucketKind: Int64] = [:]
        for entry in weekBucketEntries {
            // WHY counted-plus-transfer: `isCounted` covers new money while transfers move between buckets.
            guard BucketService.isCounted(entry) || entry.sourceEnum == .transfer else { continue }
            BucketService.applyBucketAttribution(entry, to: &balances)
        }
        return balances
    }

    /// Week-filtered ledger entries for a profile's payout week.
    /// WHY: centralises WeekMath.weekRange so views never compute week boundaries directly.
    static func weekLedgerEntries(
        for period: AllowancePeriodCache,
        from ledgers: [LedgerEntryCache]
    ) -> [LedgerEntryCache] {
        weekBucketEntries(for: period, from: ledgers)
    }

    /// Manual-vs-weekly classification per shared contract: a paid period counts
    /// as early only when its stored `paidDate` precedes the week's exclusive upper bound.
    /// WHY paidDate: wall-clock `now` cannot classify history — only the stamp distinguishes a mid-week manual payout from a week-close settlement.
    static func isEarlyPayout(for period: AllowancePeriodCache) -> Bool {
        guard let paidDate = period.paidDate else { return false }
        return isWeekOpen(weekOf: period.weekOf, now: paidDate)
    }

    /// WHY single gate: week-open plus new-earnings plus quest-gold floor travel together so runPayout and settleCurrentWeek cannot drift.
    static func shouldSupplement(weekOf: Date, now: Date, totalEarned: Int64, settledPaid: Int64, goldFromQuests: Int64) -> Bool {
        guard isWeekOpen(weekOf: weekOf, now: now),
              totalEarned > settledPaid else { return false }
        return max(Int64(0), goldFromQuests - settledPaid) > 0
    }

    /// WHY one helper: the still-open comparison lives here so `isEarlyPayout(for:)` and `shouldSupplement` cannot drift.
    private static func isWeekOpen(weekOf: Date, now: Date) -> Bool {
        now < WeekMath.weekRange(starting: weekOf).upperBound
    }

    /// WHY payout scope: deterministic base plus bucket suffix isolates the split from week activity.
    static func payoutLinkedEntries(
        for period: AllowancePeriodCache,
        from ledgers: [LedgerEntryCache]
    ) -> [LedgerEntryCache] {
        let base = DeterministicRecordID.payout(periodRecordName: period.recordName)
        let prefix = "\(base)-"
        // WHY profile scope: deterministic IDs are unique, but a profile check keeps cross-hero collisions fail-closed.
        return ledgers.filter {
            ($0.recordName == base || $0.recordName.hasPrefix(prefix)) && $0.profileRecordName == period.profileRecordName
        }
    }
}
