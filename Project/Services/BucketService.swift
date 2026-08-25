//
//  BucketService.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import CloudKit
import Foundation
import Observation

/// Transfer-specific errors surfaced to the UI with human-readable descriptions.
enum BucketServiceError: Error, LocalizedError, Equatable, Sendable {
    case insufficientFunds(available: Double, requested: Double)
    case sameBucket
    case invalidAmount
    case unauthorized
    case persistenceFailed
    case missingDependencies

    var errorDescription: String? {
        switch self {
        case let .insufficientFunds(available, requested):
            "You only have \(CurrencyFormatter.string(available)) in this bucket — can't transfer \(CurrencyFormatter.string(requested))."
        case .sameBucket:
            "Pick two different buckets to move money between."
        case .invalidAmount:
            "Enter a valid positive amount."
        case .unauthorized:
            "Only the bucket's owner can move money between buckets."
        case .persistenceFailed:
            "Could not save the transfer. Please try again."
        case .missingDependencies:
            "Something went wrong. Please try again."
        }
    }
}

/// Computes bucket balances and payout splits across the three `BucketKind`
/// buckets. Split math runs in whole pennies so allocations always sum to the
/// exact payout total. Split percentages are a future-only snapshot: they are
/// read once at payout time and never rebalance historical ledger entries.
@MainActor
@Observable
final class BucketService {
    var cacheService: CacheService?
    var syncCoordinator: CKSyncEngineCoordinator?
    var appState: AppState?

    init(cacheService: CacheService? = nil,
         syncCoordinator: CKSyncEngineCoordinator? = nil,
         appState: AppState? = nil)
    {
        self.cacheService = cacheService
        self.syncCoordinator = syncCoordinator
        self.appState = appState
    }

    // MARK: - Split Math

    /// One bucket's share of a single payout, in whole pennies.
    struct BucketShare: Equatable, Sendable {
        let kind: BucketKind
        var pennies: Int
    }

    /// Splits `totalPennies` across the three buckets using the largest
    /// remainder method so the shares sum exactly to the total — a payout can
    /// never gain or lose a penny to rounding. Percentages are normalized
    /// against their own sum, so a config that doesn't total 100 still
    /// conserves every penny; an all-zero config fails safe to spend, matching
    /// the pre-bucket default where earnings stayed in the wallet.
    static func splitPennies(_ totalPennies: Int,
                             spendPercent: Int,
                             shortPercent: Int,
                             longPercent: Int) -> [BucketShare]
    {
        let weights: [(kind: BucketKind, percent: Int)] = [
            (.spend, max(0, spendPercent)),
            (.shortTermSave, max(0, shortPercent)),
            (.longTermSave, max(0, longPercent))
        ]
        let totalWeight = weights.reduce(0) { $0 + $1.percent }
        guard totalWeight > 0 else {
            return [.init(kind: .spend, pennies: totalPennies)]
        }

        let exactShares = weights.map { Double(totalPennies) * Double($0.percent) / Double(totalWeight) }
        var shares = zip(weights, exactShares).map {
            BucketShare(kind: $0.kind, pennies: Int($1.rounded(.down)))
        }

        // Leftover pennies (the discarded fractions) go to the buckets with
        // the largest fractional remainders; ties resolve in bucket order so
        // the same input always produces the same allocation.
        let remainders = exactShares.map { $0.truncatingRemainder(dividingBy: 1) }
        let order = weights.indices.sorted {
            remainders[$0] != remainders[$1]
                ? remainders[$0] > remainders[$1]
                : $0 < $1
        }
        var leftover = totalPennies - shares.reduce(0) { $0 + $1.pennies }
        for index in order where leftover > 0 {
            shares[index].pennies += 1
            leftover -= 1
        }
        return shares
    }

    /// Convenience overload reading the split snapshot off a profile record.
    static func splitPennies(_ totalPennies: Int, profile: Profile) -> [BucketShare] {
        splitPennies(totalPennies,
                     spendPercent: profile.splitPercentSpend,
                     shortPercent: profile.splitPercentShort,
                     longPercent: profile.splitPercentLong)
    }

    // MARK: - Balance Attribution

    /// Balance per bucket, summed from ledger entries carrying an explicit
    /// `bucketKind` attribution. Transfer entries (`source == "transfer"`) also
    /// debit their `fromBucket` — this keeps ONE ledger entry per transfer while
    /// both the source and destination buckets reflect the movement.
    func bucketBalances(profileRecordName: String, familyRecordName: String) -> [BucketKind: Double] {
        guard let cacheService else { return [:] }
        var balances: [BucketKind: Double] = [:]
        for entry in cacheService.fetchLedgerEntries(
            profileRecordName: profileRecordName,
            family: familyRecordName
        ) {
            // Transfer entries debit fromBucket separately so both sides of
            // the movement are reflected without a second ledger row.
            if entry.source == "transfer",
               let fromRaw = entry.fromBucket,
               let fromKind = BucketKind(rawValue: fromRaw)
            {
                balances[fromKind, default: 0] -= entry.amount
            }
            guard let kind = entry.bucketKindEnum else { continue }
            balances[kind, default: 0] += entry.amount
        }
        return balances
    }

    // MARK: - Transfers

    /// Moves money between two buckets for the given profile. Creates exactly
    /// ONE ledger entry (source = "transfer", fromBucket → toBucket) with a
    /// deterministic ID so CloudKit dedupes across devices. The debit side is
    /// reflected by `bucketBalances` subtracting from `fromBucket` directly.
    ///
    /// - Throws `BucketServiceError.insufficientFunds` when the source bucket
    ///   doesn't have enough; `.sameBucket` when from == to; `.unauthorized`
    ///   when the caller is not the bucket owner.
    func transfer(from: BucketKind,
                  to: BucketKind,
                  amount: Double,
                  profile: Profile,
                  family: Family) async throws -> LedgerEntry
    {
        guard from != to else {
            throw BucketServiceError.sameBucket
        }
        guard amount.isFinite, amount > 0 else {
            throw BucketServiceError.invalidAmount
        }

        // Self-ownership gate: a child can only transfer their own funds.
        guard let acting = appState?.currentProfile,
              acting.id == profile.id
        else {
            throw BucketServiceError.unauthorized
        }

        guard let cacheService,
              let syncCoordinator,
              let appState
        else {
            throw BucketServiceError.missingDependencies
        }

        // Family-scope guard: the transfer must target the active family so a
        // stale or mismatched scope cannot produce phantom ledger entries.
        try ActiveFamilyScopeGuard.requireActiveFamily(
            familyRecordName: family.id.recordName,
            appState: appState
        )

        // Check available balance in the source bucket.
        let balances = bucketBalances(
            profileRecordName: profile.id.recordName,
            familyRecordName: family.id.recordName
        )
        let available = balances[from] ?? 0
        guard available >= amount else {
            throw BucketServiceError.insufficientFunds(available: available, requested: amount)
        }

        // Deterministic ID: one transfer per (profile, day, from, to) pair
        // so a retry on the same day is idempotent at the CloudKit level.
        let unixDay = Int(Date().timeIntervalSince1970 / 86400)
        let recordName = "transfer-\(profile.id.recordName)-\(unixDay)-\(from.rawValue)-\(to.rawValue)"

        let entry = LedgerEntry(
            profile: CKRecord.Reference(recordID: profile.id, action: .none),
            amount: amount,
            description: "Transfer from \(from.displayName) to \(to.displayName)",
            date: Date(),
            source: "transfer",
            bucketKind: to.rawValue,
            fromBucket: from.rawValue,
            toBucket: to.rawValue,
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: recordName, zoneID: family.id.zoneID)
        )

        cacheService.upsertLedgerEntry(entry)
        syncCoordinator.enqueueSave(recordID: entry.id, isOwner: appState.isZoneOwner)
        return entry
    }
}
