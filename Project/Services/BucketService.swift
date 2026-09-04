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

    /// Single-source attribution formula for bucket balances: an entry credits its `bucketKind`, and a
    /// transfer entry ALSO debits its `fromBucket` — keeping ONE ledger row per transfer while both sides
    nonisolated static func applyBucketAttribution(_ entry: LedgerEntryCache, to balances: inout [BucketKind: Double]) {
        // WHY single-count: goal entries mark allocation of already-counted deposit/quest funds, not new money.
        if entry.sourceEnum == .goal {
            return
        }
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
        // WHY single-count: goal entries reuse deposit/quest pennies already summed above.
        ledgers.filter { $0.profileRecordName == profileRecordName && $0.sourceEnum != .goal }.reduce(0) { $0 + $1.amount }
    }

    nonisolated static func bucketBalances(for ledgers: [LedgerEntryCache], profileRecordName: String) -> [BucketKind: Double] {
        var balances: [BucketKind: Double] = [:]
        for entry in ledgers where entry.profileRecordName == profileRecordName {
            applyBucketAttribution(entry, to: &balances)
        }
        return balances
    }

    /// WHY cache-first: Spend warnings read already-fetched @Query rows via
    /// attribution so sheets never wait on CloudKit.
    nonisolated static func resolvedSpendBalance(for ledgers: [LedgerEntryCache], profileRecordName: String) -> Double {
        bucketBalances(for: ledgers, profileRecordName: profileRecordName)[.spend] ?? 0
    }

    // Balance per bucket via `applyBucketAttribution` over ledger entries with `bucketKind`.
    // WHY: profile pushdown — store predicate scopes by profile so 1500 ledgers fetch ~500 per child, not all rows.
    func bucketBalances(profileRecordName: String, familyRecordName: String) -> [BucketKind: Double] {
        let entries = cacheService.fetchLedgerEntries(
            profileRecordName: profileRecordName,
            family: familyRecordName
        )
        return Self.bucketBalances(for: entries, profileRecordName: profileRecordName)
    }

    // MARK: - Transfers

    /// Deterministic-ID: `transferID` is `"\(dayBucket)-\(from)-\(to)"` via `WeekMath.dayBucket` (UTC) → `recordName` `transfer-{profile}-{transferID}`.
    /// Idempotent via CKSyncEngine dedupe; per-day guard is `hasTransferredToday`.
    /// WHY UTC: `Calendar.iso8601UTC` keeps same instant in same bucket on every device.
    /// Atomic mint: caller passes the already-captured `Date`; service derives `dayBucket`
    /// and `transferID` from that single instant so view/service cannot straddle 00:00 UTC.
    func transfer(from: BucketKind,
                  to: BucketKind,
                  amount: Double,
                  profile: Profile,
                  family: Family,
                  at date: Date) async throws -> LedgerEntry
    {
        // WHY single capture: `date` is the caller-captured instant — `dayBucket`, `transferID`
        // and `entry.date` all derive from it, eliminating the successive-Date() TOCTOU at UTC midnight.
        let dayBucket = WeekMath.dayBucket(for: date)
        let transferID = Self.deterministicTransferID(dayBucket: dayBucket, from: from, to: to)
        return try await transferInternal(
            from: from,
            to: to,
            amount: amount,
            profile: profile,
            family: family,
            transferID: transferID,
            date: date,
            dayBucket: dayBucket
        )
    }

    /// Legacy deterministic-ID entry point — retained for existing callers and tests.
    /// Validates `transferID` with ±1 dayBucket tolerance so a view-captured `Date()` that
    /// straddled UTC midnight with the service's `Date()` still succeeds (with skew log)
    /// instead of spuriously throwing `invalidTransferID`/`duplicateTodayTransfer`.
    func transfer(from: BucketKind,
                  to: BucketKind,
                  amount: Double,
                  profile: Profile,
                  family: Family,
                  transferID: String) async throws -> LedgerEntry
    {
        // WHY single `now` avoids TOCTOU straddle — `todayBucket` and `entry.date` stay consistent.
        let now = Date()
        let todayBucket = WeekMath.dayBucket(for: now)
        logger
            .debug(
                "BucketService.transfer local dayBucket \(todayBucket, privacy: .public) transferID \(transferID, privacy: .private) timestamp \(now.timeIntervalSince1970, privacy: .public)"
            )
        try validateTransferIDWithTolerance(transferID, todayBucket: todayBucket, from: from, to: to)
        // The dedupe bucket is the one encoded in the transferID (view's intent) when tolerance
        // allowed a ±1 skew; otherwise it matches todayBucket. Using the encoded bucket keeps
        // per-day guard aligned with the recordName that will actually be written.
        let dedupeBucket = parseDayBucket(from: transferID) ?? todayBucket
        return try await transferInternal(
            from: from,
            to: to,
            amount: amount,
            profile: profile,
            family: family,
            transferID: transferID,
            date: now,
            dayBucket: dedupeBucket
        )
    }

    private func transferInternal(from: BucketKind,
                                  to: BucketKind,
                                  amount: Double,
                                  profile: Profile,
                                  family: Family,
                                  transferID: String,
                                  date: Date,
                                  dayBucket: Int) async throws -> LedgerEntry
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
        guard !hasTransferredToday(
            profileRecordName: profile.id.recordName,
            familyRecordName: family.id.recordName,
            dayBucket: dayBucket,
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

    /// Canonical deterministic transferID for a UTC dayBucket and pair — `transfer-{profile}-{transferID}` dedupes via CKSyncEngine.
    /// WHY UTC: `WeekMath.dayBucket` is quantized via `Calendar.iso8601UTC` so same instant yields same bucket.
    nonisolated static func deterministicTransferID(dayBucket: Int, from: BucketKind, to: BucketKind) -> String {
        "\(dayBucket)-\(from.rawValue)-\(to.rawValue)"
    }

    // MARK: - Per-Day/Per-Pair Guard

    private func validateTransferID(_ transferID: String, dayBucket: Int, from: BucketKind, to: BucketKind) throws {
        guard !transferID.isEmpty else { throw BucketServiceError.invalidTransferID }
        let expected = Self.deterministicTransferID(dayBucket: dayBucket, from: from, to: to)
        guard transferID == expected else { throw BucketServiceError.invalidTransferID }
    }

    private func validateTransferIDWithTolerance(_ transferID: String, todayBucket: Int, from: BucketKind, to: BucketKind) throws {
        guard !transferID.isEmpty else { throw BucketServiceError.invalidTransferID }
        let expected = Self.deterministicTransferID(dayBucket: todayBucket, from: from, to: to)
        if transferID == expected {
            return
        }
        // Tolerance for TOCTOU at UTC midnight: view captured Date() just before/after
        // midnight while service captured on the other side. Allow ±1 bucket with skew log.
        for offset in [-1, 1] {
            let neighbor = todayBucket + offset
            guard neighbor >= 0 else { continue }
            let neighborID = Self.deterministicTransferID(dayBucket: neighbor, from: from, to: to)
            if transferID == neighborID {
                logger
                    .warning(
                        """
                        BucketService.transfer TOCTOU tolerance: accepted transferID dayBucket \
                        \(neighbor, privacy: .public) vs service today \(todayBucket, privacy: .public) \
                        within ±1 (midnight straddle)
                        """
                    )
                WeekMath.logTransferSkewIfNeeded(localDate: WeekMath.utcDateRange(forDayBucket: neighbor).lowerBound, serverDate: Date())
                return
            }
        }
        throw BucketServiceError.invalidTransferID
    }

    private func parseDayBucket(from transferID: String) -> Int? {
        // transferID is "\(dayBucket)-\(from)-\(to)" — dayBucket is the leading integer.
        guard let dash = transferID.firstIndex(of: "-") else { return nil }
        return Int(transferID[..<dash])
    }

    // Returns true when a transfer between `from` → `to` already exists for `profile` in `family` on UTC `dayBucket`.
    // WHY: predicate pushdown via `fetchTransfers` keeps guard indexed — store filters by day range at DB level.
    // Single-sourced guard: BucketTransferView reuses this via BucketService so view and service stay indexed.
    func hasTransferredToday(
        profileRecordName: String,
        familyRecordName: String,
        dayBucket: Int,
        from: BucketKind,
        to: BucketKind
    ) -> Bool {
        let fromRaw = from.rawValue
        let toRaw = to.rawValue
        // WHY: exact bucket for dedupe; ±1 buckets are diagnostic-only so midnight skew still logs.
        let matched = cacheService.fetchTransfers(
            profileRecordName: profileRecordName,
            familyRecordName: familyRecordName,
            from: fromRaw,
            to: toRaw,
            dayBucket: dayBucket
        )
        logMidnightSkewIfNeeded(
            profileRecordName: profileRecordName,
            familyRecordName: familyRecordName,
            from: fromRaw,
            to: toRaw,
            dayBucket: dayBucket,
            matched: matched
        )
        return !matched.isEmpty
    }

    // WHY: diagnostic fetch covers dayBucket ±1 so entries near UTC midnight still trigger skew logging.
    // WHY: neighbor fetches are gated behind near-midnight check to avoid 3 indexed fetches on every transfer.
    private func logMidnightSkewIfNeeded(
        profileRecordName: String,
        familyRecordName: String,
        from fromRaw: String,
        to toRaw: String,
        dayBucket: Int,
        matched: [LedgerEntryCache]
    ) {
        // Single now avoids repeated Date() calls and TOCTOU at midnight.
        let now = Date()
        let shouldCheckNeighbors = WeekMath.isNearUTCMidnight(now) || matched.contains(where: { WeekMath.isNearUTCMidnight($0.date) })
        var candidates = matched
        if shouldCheckNeighbors {
            for offset in [-1, 1] {
                let neighbor = dayBucket + offset
                guard neighbor >= 0 else { continue }
                let extra = cacheService.fetchTransfers(
                    profileRecordName: profileRecordName,
                    familyRecordName: familyRecordName,
                    from: fromRaw,
                    to: toRaw,
                    dayBucket: neighbor
                )
                candidates.append(contentsOf: extra)
            }
        }
        for entry in candidates {
            WeekMath.logTransferSkewIfNeeded(localDate: entry.date, serverDate: now)
            WeekMath.logTransferSkewIfNeeded(localDate: now, serverDate: entry.date)
            let entryBucket = WeekMath.dayBucket(for: entry.date)
            // WHY: only log hint when buckets differ by 1 and either side is near midnight — the skew case.
            guard abs(entryBucket - dayBucket) == 1 else { continue }
            guard WeekMath.isNearUTCMidnight(entry.date) || WeekMath.isNearUTCMidnight(now) else { continue }
            let ed = entry.date
            logger
                .warning(
                    "Near-midnight skew: existing dayBucket \(entryBucket, privacy: .public) vs today \(dayBucket, privacy: .public) date \(ed, privacy: .private) within 2h of UTC midnight"
                )
            #if DEBUG
                logger
                    .debug(
                        "DEBUG near-midnight skew context: entryBucket \(entryBucket, privacy: .public) todayBucket \(dayBucket, privacy: .public) date \(ed, privacy: .private)"
                    )
            #endif
        }
    }
}
