//
//  BucketService.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import CloudKit
import CryptoKit
import Foundation
import Observation
import os

/// Transfer-specific errors surfaced to the UI with human-readable descriptions.
enum BucketServiceError: Error, LocalizedError, Equatable, Sendable {
    case insufficientFunds(available: Int64, requested: Int64)
    case sameBucket
    case invalidAmount
    case unauthorized
    case persistenceFailed
    case duplicateTodayTransfer

    var errorDescription: String? {
        switch self {
        case let .insufficientFunds(available, requested):
            "You only have \(CurrencyFormatter.string(pennies: available)) in this bucket — can't transfer \(CurrencyFormatter.string(pennies: requested))."
        case .sameBucket:
            "Pick two different buckets to move money between."
        case .invalidAmount:
            "Enter a valid positive amount."
        case .unauthorized:
            "Only the bucket's owner can move money between buckets."
        case .persistenceFailed:
            "Could not save the transfer. Please try again."
        case .duplicateTodayTransfer:
            "This transfer already exists."
        }
    }
}

/// Computes bucket balances and payout splits across the three `BucketKind` buckets.
///
/// Single-count contract (bucket-only): counted = bucketKind != nil && source != goal && source != transfer; bonus = counted && source != quest.
/// WHY parity: transfers net zero via debit+credit in bucket math but stay excluded from ledger/total.
@MainActor
@Observable
final class BucketService {
    private static let staticLogger = Logger(category: "BucketService")
    private let logger = Logger(category: "BucketService")
    let cacheService: any CacheServicing
    let syncCoordinator: any SyncEnqueuing
    let appState: AppState

    init(cacheService: any CacheServicing,
         syncCoordinator: any SyncEnqueuing,
         appState: AppState)
    {
        self.cacheService = cacheService
        self.syncCoordinator = syncCoordinator
        self.appState = appState
    }

    private static func resolveCache(_ cacheService: (any CacheServicing)?) -> any CacheServicing {
        if let cacheService {
            return cacheService
        }
        Self.staticLogger.warning("BucketService initialized without cacheService; using fallback in-memory cache.")
        return CacheService.inMemoryFallback(logger: Self.staticLogger)
    }

    /// Convenience for read-only callers that only need balance attribution.
    /// Uses the same container-backed cache instance but a no-op coordinator.
    convenience init(cacheService: any CacheServicing) {
        self.init(cacheService: cacheService, syncCoordinator: NoopSyncEnqueuing(), appState: AppState())
    }

    /// Legacy optional shim for call sites that have not yet migrated.
    convenience init(cacheService: (any CacheServicing)? = nil) {
        self.init(cacheService: Self.resolveCache(cacheService))
    }

    convenience init(cacheService: any CacheServicing, syncCoordinator: (any SyncEnqueuing)?, appState: AppState) {
        self.init(cacheService: cacheService, syncCoordinator: syncCoordinator ?? NoopSyncEnqueuing(), appState: appState)
    }

    /// Optional-cache shim that also forwards an optional sync coordinator.
    convenience init(cacheService: (any CacheServicing)?, syncCoordinator: (any SyncEnqueuing)?, appState: AppState) {
        self.init(cacheService: Self.resolveCache(cacheService), syncCoordinator: syncCoordinator, appState: appState)
    }

    // MARK: - Split Math

    /// One bucket's share of a single payout, in whole pennies.
    struct BucketShare: Equatable, Sendable {
        let kind: BucketKind
        var pennies: Int
    }

    /// Splits `totalPennies` across the three buckets using the largest remainder method so the shares sum
    /// exactly to the total — a payout can never gain or lose a penny to rounding.
    nonisolated static func splitPennies(_ totalPennies: Int,
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
    nonisolated static func splitPennies(_ totalPennies: Int, profile: Profile) -> [BucketShare] {
        splitPennies(totalPennies,
                     spendPercent: profile.splitPercentSpend,
                     shortPercent: profile.splitPercentShort,
                     longPercent: profile.splitPercentLong)
    }

    // MARK: - Balance Attribution

    /// WHY single source: every balance shares one counted predicate; check via this, never source directly.
    nonisolated static func isCounted(_ entry: some LedgerEntryProtocol) -> Bool {
        entry.isCounted
    }

    /// WHY single source: bonus totals share one quest-excluding predicate; check via this, never source directly.
    nonisolated static func isBonusCounted(_ entry: some LedgerEntryProtocol) -> Bool {
        entry.isBonusCounted
    }

    /// Single-source attribution: credits bucketKind; transfers also debit fromBucket so one row moves both sides.
    nonisolated static func applyBucketAttribution(_ entry: LedgerEntryCache, to balances: inout [BucketKind: Int64]) {
        // WHY bucket-only: nil-bucket rows are wiped residue, never live money.
        guard let kind = entry.bucketKindEnum else { return }
        // WHY single-count: goal entries reuse counted funds, not new money.
        if entry.sourceEnum == .goal {
            return
        }
        if entry.sourceEnum == .transfer,
           let fromRaw = entry.fromBucket,
           let fromKind = BucketKind(rawValue: fromRaw)
        {
            balances[fromKind, default: 0] -= entry.amount
        }
        balances[kind, default: 0] += entry.amount
    }

    /// WHY parity: counted excludes goal/transfer/nil-bucket so ledger total matches bucket total; transfers net zero via debit+credit.
    nonisolated static func ledgerBalance(for ledgers: [LedgerEntryCache], profileRecordName: String) -> Int64 {
        ledgers.filter { $0.profileRecordName == profileRecordName && Self.isCounted($0) }.reduce(0) { $0 + $1.amount }
    }

    nonisolated static func bucketBalances(for ledgers: [LedgerEntryCache], profileRecordName: String) -> [BucketKind: Int64] {
        var balances: [BucketKind: Int64] = [:]
        for entry in ledgers where entry.profileRecordName == profileRecordName {
            applyBucketAttribution(entry, to: &balances)
        }
        return balances
    }

    /// WHY cache-first: Spend warnings read already-fetched @Query rows via
    /// attribution so sheets never wait on CloudKit.
    nonisolated static func resolvedSpendBalance(for ledgers: [LedgerEntryCache], profileRecordName: String) -> Int64 {
        bucketBalances(for: ledgers, profileRecordName: profileRecordName)[.spend] ?? 0
    }

    /// WHY one helper: bucket sum is the total on every surface; matches ledgerBalance (transfers net zero).
    nonisolated static func totalBalance(for ledgers: [LedgerEntryCache], profileRecordName: String) -> Int64 {
        bucketBalances(for: ledgers, profileRecordName: profileRecordName).values.reduce(0, +)
    }

    /// WHY one sum: precomputed bucket parts combine identically on every surface.
    nonisolated static func totalBalance(bucketBalances: [BucketKind: Int64]) -> Int64 {
        bucketBalances.values.reduce(0, +)
    }

    // Balance per bucket via `applyBucketAttribution` over ledger entries with `bucketKind`.
    // WHY: profile pushdown — store predicate scopes by profile so 1500 ledgers fetch ~500 per child, not all rows.
    func bucketBalances(profileRecordName: String, familyRecordName: String) -> [BucketKind: Int64] {
        let entries = cacheService.fetchLedgerEntries(
            profileRecordName: profileRecordName,
            family: familyRecordName
        )
        return Self.bucketBalances(for: entries, profileRecordName: profileRecordName)
    }

    // MARK: - Transfers

    /// Unlimited transfers via millisecond-timestamp deterministic IDs: `transferID` is `"\(ms)-\(cents)-\(from)-\(to)"` → `recordName` `transfer-{profile}-{transferID}`.
    /// Replay-safe: an identical retry (same ms, cents, pair) dedupes via `duplicateTodayTransfer`; divergent collisions extend deterministically.
    /// WHY single instant: caller passes the already-captured `Date`; service derives `transferID`
    /// from that single instant so view/service cannot mint mismatched IDs.
    /// Transfers money between buckets using millisecond timestamp + cents in the deterministic ID,
    /// allowing unlimited transfers per day without record name collisions.
    func transfer(from: BucketKind,
                  to: BucketKind,
                  amount: Int64,
                  profile: Profile,
                  family: Family,
                  at date: Date) async throws -> LedgerEntry
    {
        let ms = Int(date.timeIntervalSince1970 * 1000)
        let cents = Int(abs(amount))
        let transferID = "\(ms)-\(cents)-\(from.rawValue)-\(to.rawValue)"
        return try await transferInternal(
            from: from,
            to: to,
            amount: amount,
            profile: profile,
            family: family,
            transferID: transferID,
            date: date
        )
    }

    /// Legacy deterministic-ID entry point — retained for existing callers and tests.
    func transfer(from: BucketKind,
                  to: BucketKind,
                  amount: Int64,
                  profile: Profile,
                  family: Family,
                  transferID: String) async throws -> LedgerEntry
    {
        // WHY: Legacy 3-part IDs use day-granularity dedup, so a fresh Date()
        // is fine. Modern 4-part ms-format IDs encode the original instant;
        // reconstructing it keeps isSameMillisecond dedup consistent across retries.
        let date = if isLegacyTransferID(transferID) {
            Date()
        } else if let ms = transferID.split(separator: "-").first.flatMap({ Int($0) }) {
            Date(timeIntervalSince1970: Double(ms) / 1000.0)
        } else {
            Date()
        }
        logger
            .debug(
                "BucketService.transfer transferID \(transferID, privacy: .private) timestamp \(date.timeIntervalSince1970, privacy: .public)"
            )
        // WHY single gate: transferInternal dedupes identical retries and extends divergent collisions.
        return try await transferInternal(
            from: from,
            to: to,
            amount: amount,
            profile: profile,
            family: family,
            transferID: transferID,
            date: date
        )
    }

    private func transferInternal(from: BucketKind,
                                  to: BucketKind,
                                  amount: Int64,
                                  profile: Profile,
                                  family: Family,
                                  transferID: String,
                                  date: Date) async throws -> LedgerEntry
    {
        guard from != to else {
            throw BucketServiceError.sameBucket
        }
        guard amount > 0 else {
            throw BucketServiceError.invalidAmount
        }

        // Self-ownership gate: a child can only transfer their own funds.
        guard let acting = appState.currentProfile,
              acting.id == profile.id
        else {
            throw BucketServiceError.unauthorized
        }

        // Family-scope guard: the transfer must target the active family so a
        // stale or mismatched scope cannot produce phantom ledger entries.
        try ActiveFamilyScopeGuard.requireActiveFamily(
            familyRecordName: family.id.recordName,
            appState: appState
        )

        // Check available balance in the source bucket.
        let entries = cacheService.fetchLedgerEntries(
            profileRecordName: profile.id.recordName,
            family: family.id.recordName
        )
        let balances = Self.bucketBalances(for: entries, profileRecordName: profile.id.recordName)
        let available = balances[from] ?? 0
        guard available >= amount else {
            throw BucketServiceError.insufficientFunds(available: available, requested: amount)
        }

        var effectiveTransferID = transferID
        // WHY single source: DeterministicRecordID owns transfer-profile-transferID so retries dedupe via CKSyncEngine.
        var recordName = DeterministicRecordID.transfer(profileRecordName: profile.id.recordName, transferID: effectiveTransferID)
        // WHY replay-safe: an identical retry must dedupe, never fork a duplicate row.
        // Only a truly divergent payload extends, deterministically so every device converges.
        var attempt = 0
        while let existing = cacheService.fetchLedgerEntry(recordName: recordName, family: family.id.recordName) {
            if isIdenticalTransfer(existing, amount: amount, from: from, to: to, date: date, transferID: transferID) {
                throw BucketServiceError.duplicateTodayTransfer
            }
            // WHY unbounded convergent extension: every attempt hashes full payload so all devices agree on each fallback name.
            effectiveTransferID = extendedTransferID(
                base: transferID,
                amount: amount,
                from: from,
                to: to,
                date: date,
                attempt: attempt
            )
            recordName = DeterministicRecordID.transfer(profileRecordName: profile.id.recordName, transferID: effectiveTransferID)
            attempt += 1
        }

        let entry = LedgerEntry(
            profile: CKRecord.Reference(recordID: profile.id, action: .none),
            amount: amount,
            description: "Transfer from \(from.displayName) to \(to.displayName)",
            date: date,
            source: LedgerSource.transfer.rawValue,
            bucketKind: to.rawValue,
            fromBucket: from.rawValue,
            toBucket: to.rawValue,
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: recordName, zoneID: family.id.zoneID)
        )

        await cacheService.upsertLedgerEntry(entry)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: entry.id, appState: appState, logger: logger, context: "BucketService.transfer")
        return entry
    }

    // MARK: - Deterministic-ID Helpers

    /// Legacy per-day transferID for a UTC dayBucket and pair — `transfer-{profile}-{transferID}` dedupes via CKSyncEngine.
    /// WHY legacy-only: new transfers mint `"\(ms)-\(cents)-\(from)-\(to)"` via `transfer(at:)` for unlimited moves; this per-day format remains only for existing callers and
    /// tests.
    nonisolated static func deterministicTransferID(dayBucket: Int, from: BucketKind, to: BucketKind) -> String {
        "\(dayBucket)-\(from.rawValue)-\(to.rawValue)"
    }

    /// WHY deterministic extension: hash all discriminating fields including the date key mirrored from
    /// identity matching so divergent dates fork on the first attempt on every device, never a random fork.
    private func extendedTransferID(base: String, amount: Int64, from: BucketKind, to: BucketKind, date: Date, attempt: Int) -> String {
        let cents = Int(abs(amount))
        // WHY mirror identity: legacy IDs discriminate by UTC day while ms IDs discriminate by millisecond.
        let dateKey = isLegacyTransferID(base) ? String(WeekMath.dayBucket(for: date)) : String(Int(date.timeIntervalSince1970 * 1000))
        let payload = "\(base)|\(cents)|\(from.rawValue)|\(to.rawValue)|\(dateKey)|\(attempt)"
        let hash = SHA256.hash(data: Data(payload.utf8))
        let hex = hash.hexPrefix(4)
        return "\(base)-\(hex)"
    }

    private func isLegacyTransferID(_ transferID: String) -> Bool {
        transferID.split(separator: "-").count == 3
    }

    private func isIdenticalTransfer(_ existing: LedgerEntryCache, amount: Int64, from: BucketKind, to: BucketKind, date: Date, transferID: String) -> Bool {
        guard existing.source == LedgerSource.transfer.rawValue else { return false }
        guard existing.fromBucket == from.rawValue, existing.toBucket == to.rawValue else { return false }
        guard existing.bucketKind == to.rawValue else { return false }
        let existingCents = Int(abs(existing.amount))
        let requestCents = Int(abs(amount))
        guard existingCents == requestCents else { return false }
        // WHY day discrimination: legacy IDs carry only day+pair so same-day retries dedupe while cross-day reuse extends.
        if isLegacyTransferID(transferID) {
            guard WeekMath.dayBucket(for: existing.date) == WeekMath.dayBucket(for: date) else { return false }
        } else {
            // WHY ms discrimination: ms-cents IDs already encode the instant so only the same millisecond replays idempotently.
            guard DeterministicRecordID.isSameMillisecond(existing.date, date) else { return false }
        }
        return true
    }

    // MARK: - Checklist Helpers

    /// Primitive overload for off-MainActor callers — pass split triple directly to avoid MainActor hop.
    nonisolated static func isDefaultSplit(spend: Int, short: Int, long: Int) -> Bool {
        spend == 100 && short == 0 && long == 0
    }
}
