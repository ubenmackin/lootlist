//
//  GoalProgressCalculator.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import CloudKit
import Foundation
import SwiftData

/// Central calculator for goal progress derived from ledger entries.
///
/// Direct-contribution path attributes deterministic `contrib-{goalRecordName}-{sourceEventID}`
/// ledger entries to their owning goal via ``DeterministicRecordID/contributionPrefix(for:)``.
/// FIFO path distributes bucket totals by creation order for ledgers that lack
/// deterministic contribution IDs. Both paths share pennies conversion and prefix
/// filtering through this single source to prevent divergence.
enum GoalProgressCalculator {
    static func allocations(goals: [GoalCache], ledgerEntries: [LedgerEntryCache]) -> [String: Int64] {
        let hasContribIDs = ledgerEntries.contains { DeterministicRecordID.isContributionRecord($0.recordName) }
        if hasContribIDs {
            return directContributionAllocations(goals: goals, ledgerEntries: ledgerEntries)
        }
        return fifoAllocations(goals: goals, ledgerEntries: ledgerEntries)
    }

    // MARK: - Shared Contribution Helpers

    /// Total pennies attributed to `goal` from deterministic contribution records.
    static func contributionPennies(for goal: GoalCache, in ledgerEntries: [LedgerEntryCache]) -> Int64 {
        let prefix = DeterministicRecordID.contributionPrefix(for: goal.recordName)
        return ledgerEntries
            .filter { $0.recordName.hasPrefix(prefix) && $0.profileRecordName == goal.profileRecordName }
            .reduce(into: Int64(0)) { acc, entry in
                acc += entry.amount
            }
    }

    /// Total currency amount attributed to `goal` from deterministic contribution records.
    static func contributionAmount(for goal: GoalCache, in ledgerEntries: [LedgerEntryCache]) -> Int64 {
        contributionPennies(for: goal, in: ledgerEntries)
    }

    /// Pennies conversion for a single ledger entry (already whole pennies).
    private static func pennies(for entry: LedgerEntryCache) -> Int64 {
        entry.amount
    }

    // MARK: - Allocation Strategies

    private static func directContributionAllocations(goals: [GoalCache], ledgerEntries: [LedgerEntryCache]) -> [String: Int64] {
        var result: [String: Int64] = [:]
        for goal in goals where goal.isListedGoal {
            let pennies = contributionPennies(for: goal, in: ledgerEntries)
            result[goal.recordName] = max(pennies, 0)
        }
        for goal in goals where result[goal.recordName] == nil {
            result[goal.recordName] = 0
        }
        return result
    }

    private static func fifoAllocations(goals: [GoalCache], ledgerEntries: [LedgerEntryCache]) -> [String: Int64] {
        var result: [String: Int64] = [:]
        // WHY display full: completed goals already hold their funds, so they render whole without consuming new bucket money.
        for goal in goals where goal.completedAt != nil && goal.isListedGoal {
            result[goal.recordName] = goal.targetAmountPennies
        }
        // WHY subtract held funds: completed targets still sit in the bucket total, so open goals split only what remains.
        let completedSums = Dictionary(grouping: goals.filter { $0.isListedGoal && $0.completedAt != nil }) {
            "\($0.profileRecordName)|\($0.bucketKind)"
        }.mapValues { $0.reduce(into: Int64(0)) { $0 += $1.targetAmountPennies } }
        // WHY open only: completed goals already hold their funds and clear via purchase, so new money cascades past them.
        let open = goals.filter(\.isActiveGoal)
        let grouped = Dictionary(grouping: open) { "\($0.profileRecordName)|\($0.bucketKind)" }
        for (key, bucketGoals) in grouped {
            let sorted = bucketGoals.sorted {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt < $1.createdAt
                }
                return $0.recordName < $1.recordName
            }
            guard let first = sorted.first else { continue }
            let profile = first.profileRecordName
            let bucket = first.bucketKind
            // WHY single-count: goal entries mark allocation of already-counted bucket funds, not new money.
            let bucketEntries = ledgerEntries.filter { $0.profileRecordName == profile && $0.bucketKind == bucket && BucketService.isCounted($0) }
            let totalPennies = bucketEntries.reduce(into: Int64(0)) { acc, entry in
                acc += pennies(for: entry)
            }
            let completedSum = completedSums[key] ?? 0
            var remaining = max(totalPennies - completedSum, 0)
            for goal in sorted {
                let alloc = min(remaining, goal.targetAmountPennies)
                result[goal.recordName] = alloc
                remaining -= alloc
            }
        }
        for goal in goals where result[goal.recordName] == nil {
            result[goal.recordName] = 0
        }
        return result
    }
}
