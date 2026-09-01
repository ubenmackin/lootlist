//
//  BucketService.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import CloudKit
import Foundation
import Observation
import os

/// Transfer-specific errors surfaced to the UI with human-readable descriptions.
enum BucketServiceError: Error, LocalizedError, Equatable, Sendable {
    case insufficientFunds(available: Double, requested: Double)
    case sameBucket
    case invalidAmount
    /// Deterministic-ID contract: transferID must be "\(dayBucket)-\(from)-\(to)" where dayBucket is UTC via WeekMath; recordName is "transfer-{profile}-{transferID}".
    case invalidTransferID
    case unauthorized
    case persistenceFailed
    case duplicateTodayTransfer

    var errorDescription: String? {
        switch self {
        case let .insufficientFunds(available, requested):
            "You only have \(CurrencyFormatter.string(available)) in this bucket — can't transfer \(CurrencyFormatter.string(requested))."
        case .sameBucket:
            "Pick two different buckets to move money between."
        case .invalidAmount:
            "Enter a valid positive amount."
        case .invalidTransferID:
            "The transfer identifier is invalid. Please try again."
        case .unauthorized:
            "Only the bucket's owner can move money between buckets."
        case .persistenceFailed:
            "Could not save the transfer. Please try again."
        case .duplicateTodayTransfer:
            "You already moved money between these buckets today. Try again tomorrow."
        }
    }
}

@MainActor
private final class NoopSync: SyncEnqueuing {
    func enqueueSave(recordID _: CKRecord.ID, isOwner _: Bool) {}
    func enqueueDelete(recordID _: CKRecord.ID, isOwner _: Bool) {}
    func batchEnqueueSave(recordIDs _: [CKRecord.ID], isOwner _: Bool) {}
}

/// Computes bucket balances and payout splits across the three `BucketKind` buckets.
@MainActor
@Observable
final class BucketService {
    private static let staticLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "BucketService")
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "BucketService")
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

    /// Convenience for read-only callers that only need balance attribution.
    /// Uses the same container-backed cache instance but a no-op coordinator.
    convenience init(cacheService: any CacheServicing) {
        self.init(cacheService: cacheService, syncCoordinator: NoopSync(), appState: AppState())
    }

    /// Legacy optional shim for call sites that have not yet migrated.
    convenience init(cacheService: (any CacheServicing)? = nil) {
        if let cacheService {
            self.init(cacheService: cacheService)
        } else {
            Self.staticLogger.warning("BucketService initialized without cacheService; using fallback in-memory cache.")
            let fallback = CacheService.inMemoryFallback(logger: Self.staticLogger)
            self.init(cacheService: fallback)
        }
    }

    convenience init(cacheService: any CacheServicing, syncCoordinator: (any SyncEnqueuing)?, appState: AppState) {
        self.init(cacheService: cacheService, syncCoordinator: syncCoordinator ?? NoopSync(), appState: appState)
    }

    /// Optional-cache shim that also forwards an optional sync coordinator.
    convenience init(cacheService: (any CacheServicing)?, syncCoordinator: (any SyncEnqueuing)?, appState: AppState) {
        if let cacheService {
            self.init(cacheService: cacheService, syncCoordinator: syncCoordinator, appState: appState)
        } else {
            Self.staticLogger.warning("BucketService initialized without cacheService; using fallback in-memory cache.")
            let fallback = CacheService.inMemoryFallback(logger: Self.staticLogger)
            self.init(cacheService: fallback, syncCoordinator: syncCoordinator, appState: appState)
        }
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

    /// Single-source attribution formula for bucket balances: an entry credits its `bucketKind`, and a
    /// transfer entry ALSO debits its `fromBucket` — keeping ONE ledger row per transfer while both sides
    nonisolated static func applyBucketAttribution(_ entry: LedgerEntryCache, to balances: inout [BucketKind: Double]) {
        if entry.sourceEnum == .transfer,
           let fromRaw = entry.fromBucket,
           let fromKind = BucketKind(rawValue: fromRaw)
        {
            balances[fromKind, default: 0] -= entry.amount
        }
        guard let kind = entry.bucketKindEnum else { return }
        balances[kind, default: 0] += entry.amount
    }

    nonisolated static func ledgerBalance(for ledgers: [LedgerEntryCache], profileRecordName: String) -> Double {
        ledgers.filter { $0.profileRecordName == profileRecordName }.reduce(0) { $0 + $1.amount }
    }

    nonisolated static func bucketBalances(for ledgers: [LedgerEntryCache], profileRecordName: String) -> [BucketKind: Double] {
        var balances: [BucketKind: Double] = [:]
        for entry in ledgers where entry.profileRecordName == profileRecordName {
            applyBucketAttribution(entry, to: &balances)
        }
        return balances
    }

    /// Balance per bucket, summed from ledger entries carrying an explicit
    /// `bucketKind` attribution via the shared `applyBucketAttribution` formula.
    func bucketBalances(profileRecordName: String, familyRecordName: String) -> [BucketKind: Double] {
        let entries = cacheService.fetchLedgerEntries(
            profileRecordName: profileRecordName,
            family: familyRecordName
        )
        return Self.bucketBalances(for: entries, profileRecordName: profileRecordName)
    }

    // MARK: - Transfers

    /// Deterministic-ID contract for money-movement transfers.
    /// Mandated path: `transferID == "\(WeekMath.dayBucket(for: Date()))-\(from.rawValue)-\(to.rawValue)"`
    /// (UTC day bucket via `WeekMath`, as used in `BucketTransferView` at call site) → `recordName`
    /// `"transfer-{profileRecordName}-{transferID}"`. This guarantees idempotency: CKSyncEngine dedupes
    /// double-runs across devices and the service-owned per-day/per-pair guard rejects same-day repeats.
    /// No fallback is permitted — every write must supply a deterministic WeekMath.dayBucket-keyed ID so
    /// cross-device dedupe via recordName is guaranteed. Per-day/per-pair guard remains service-owned
    /// via `hasTransferredToday`.
    func transfer(from: BucketKind,
                  to: BucketKind,
                  amount: Double,
                  profile: Profile,
                  family: Family,
                  transferID: String) async throws -> LedgerEntry
    {
        guard from != to else {
            throw BucketServiceError.sameBucket
        }
        guard amount.isFinite, amount > 0 else {
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
        let balances = bucketBalances(
            profileRecordName: profile.id.recordName,
            familyRecordName: family.id.recordName
        )
        let available = balances[from] ?? 0
        guard available >= amount else {
            throw BucketServiceError.insufficientFunds(available: available, requested: amount)
        }

        let now = Date()
        let todayBucket = WeekMath.dayBucket(for: now)
        logger
            .debug(
                "BucketService.transfer local dayBucket \(todayBucket, privacy: .public) transferID \(transferID, privacy: .private) timestamp \(now.timeIntervalSince1970, privacy: .public)"
            )
        try validateTransferID(transferID, dayBucket: todayBucket, from: from, to: to)
        guard !hasTransferredToday(
            profileRecordName: profile.id.recordName,
            familyRecordName: family.id.recordName,
            dayBucket: todayBucket,
            from: from,
            to: to
        ) else {
            throw BucketServiceError.duplicateTodayTransfer
        }

        let recordName = DeterministicRecordID.transfer(profileRecordName: profile.id.recordName, transferID: transferID)

        let entry = LedgerEntry(
            profile: CKRecord.Reference(recordID: profile.id, action: .none),
            amount: amount,
            description: "Transfer from \(from.displayName) to \(to.displayName)",
            date: now,
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

    /// Canonical deterministic transferID for a given UTC day bucket and pair.
    /// Callers (e.g., `BucketTransferView`) must supply `"\(WeekMath.dayBucket(for: Date()))-\(from.rawValue)-\(to.rawValue)"`
    /// so `recordName` becomes `transfer-{profile}-{transferID}` and dedupes via CKSyncEngine.
    nonisolated static func deterministicTransferID(dayBucket: Int, from: BucketKind, to: BucketKind) -> String {
        "\(dayBucket)-\(from.rawValue)-\(to.rawValue)"
    }

    // MARK: - Per-Day/Per-Pair Guard

    private func validateTransferID(_ transferID: String, dayBucket: Int, from: BucketKind, to: BucketKind) throws {
        guard !transferID.isEmpty else { throw BucketServiceError.invalidTransferID }
        let expected = Self.deterministicTransferID(dayBucket: dayBucket, from: from, to: to)
        guard transferID == expected else { throw BucketServiceError.invalidTransferID }
    }

    /// Returns true when a transfer between `from` → `to` already exists for `profile` in `family` on UTC `dayBucket`.
    private func hasTransferredToday(
        profileRecordName: String,
        familyRecordName: String,
        dayBucket: Int,
        from: BucketKind,
        to: BucketKind
    ) -> Bool {
        let entries = cacheService.fetchLedgerEntries(
            profileRecordName: profileRecordName,
            family: familyRecordName
        )
        for entry in entries where entry.sourceEnum == .transfer && entry.fromBucket == from.rawValue && entry.toBucket == to.rawValue {
            let entryBucket = WeekMath.dayBucket(for: entry.date)
            guard entryBucket != dayBucket else { continue }
            WeekMath.logTransferSkewIfNeeded(localDate: entry.date, serverDate: Date())
            WeekMath.logTransferSkewIfNeeded(localDate: Date(), serverDate: entry.date)
            guard abs(entryBucket - dayBucket) == 1 else { continue }
            if WeekMath.isNearUTCMidnight(entry.date) || WeekMath.isNearUTCMidnight(Date()) {
                let eb = entryBucket
                let tb = dayBucket
                let ed = entry.date
                logger
                    .warning(
                        "Transfer near-midnight skew hint: existing dayBucket \(eb, privacy: .public) vs today \(tb, privacy: .public) date \(ed, privacy: .private) within 2h of UTC midnight"
                    )
                #if DEBUG
                    logger.debug("DEBUG near-midnight skew context: entryBucket \(eb, privacy: .public) todayBucket \(tb, privacy: .public) date \(ed, privacy: .private)")
                #endif
            }
        }
        return entries.contains { entry in
            entry.sourceEnum == .transfer
                && entry.fromBucket == from.rawValue
                && entry.toBucket == to.rawValue
                && WeekMath.dayBucket(for: entry.date) == dayBucket
        }
    }
}
