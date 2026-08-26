//
//  InterestService.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import CloudKit
import Foundation
import os

enum InterestServiceError: LocalizedError {
    case invalidConfig

    var errorDescription: String? {
        switch self {
        case .invalidConfig:
            "Pick a save bucket and a rate above zero before enabling interest."
        }
    }
}

/// Monthly interest engine for a hero's savings buckets. Config lives on the
/// hero's `Profile` record and is edited by parents only; the credit itself is
/// applied once per calendar month inside the payout cycle, after quest
/// rewards settle. Like every money-movement path, credits are immutable
/// ledger entries with deterministic IDs (`interest-{profile}-{yyyy-MM}`), so
/// a replayed payout run or a second device applying the same month can never
/// mint two credits — CloudKit dedupes the record name across devices.
@MainActor
@Observable
final class InterestService {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "InterestService")
    private let cloudKit: any CloudKitServiceProtocol
    var cacheService: CacheService?
    var syncCoordinator: CKSyncEngineCoordinator?
    var appState: AppState?

    init(
        cloudKit: any CloudKitServiceProtocol,
        cacheService: CacheService? = nil,
        appState: AppState? = nil,
        syncCoordinator: CKSyncEngineCoordinator? = nil
    ) {
        self.cloudKit = cloudKit
        self.cacheService = cacheService
        self.appState = appState
        self.syncCoordinator = syncCoordinator
    }

    // MARK: - Deterministic Identity

    /// UTC calendar keeps the month key identical on every device — a shared-
    /// family participant in another timezone must derive the same
    /// deterministic ID for the same month or dedup breaks.
    static func monthKey(for date: Date, calendar: Calendar = .iso8601UTC) -> String {
        let components = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }

    static func recordName(profileRecordName: String, monthKey: String) -> String {
        "interest-\(profileRecordName)-\(monthKey)"
    }

    // MARK: - Config

    /// Parent-only edit of the hero's monthly interest config. Client-side
    /// role check is defense-in-depth per the authorization model; unauthorized
    /// callers get `FamilyServiceError.unauthorized`.
    @discardableResult
    func updateInterestConfig(profile: Profile,
                              enabled: Bool,
                              bucket: BucketKind?,
                              rateBps: Int,
                              isCompound: Bool) async throws -> Profile
    {
        guard let appState, let acting = appState.currentProfile, acting.role.isParent else {
            throw FamilyServiceError.unauthorized
        }
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            familyRecordName: profile.family.recordID.recordName,
            zoneID: profile.id.zoneID,
            appState: appState,
            cloudKit: cloudKit
        )
        if enabled {
            guard bucket != nil, rateBps > 0 else {
                throw InterestServiceError.invalidConfig
            }
        }

        var updated = profile
        updated.interestEnabled = enabled
        updated.interestBucket = bucket?.rawValue
        updated.interestRateBps = max(0, rateBps)
        updated.interestIsCompound = isCompound

        await cacheService?.upsertProfile(updated)
        if appState.currentProfile?.id == updated.id {
            appState.currentProfile = updated
        }
        syncCoordinator?.enqueueSave(recordID: updated.id, isOwner: appState.isZoneOwner)
        return updated
    }

    // MARK: - Monthly Application

    /// Whole-penny interest, always rounded down so rounding can never mint
    /// value that wasn't earned.
    static func interestPennies(basePennies: Int, rateBps: Int) -> Int {
        guard basePennies > 0, rateBps > 0 else { return 0 }
        return basePennies * rateBps / 10000
    }

    /// Applies at most one interest credit for the hero's configured bucket in
    /// the month containing `date`. Callers run this inside the payout cycle
    /// after quest rewards settle; the `AllowancePeriod.status == .paid`
    /// skip-guard upstream means settlement runs at most once per period, and
    /// the deterministic month ID makes even an out-of-band replay a no-op.
    ///
    /// Returns the minted entry, or `nil` when nothing was owed: config
    /// disabled, no balance to earn on, a sub-penny credit, or the month
    /// already credited.
    @discardableResult
    func applyMonthlyInterest(profile: Profile,
                              family: Family,
                              date: Date = Date()) async throws -> LedgerEntry?
    {
        guard let appState, let acting = appState.currentProfile, acting.role.isParent else {
            throw FamilyServiceError.unauthorized
        }
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            family: family,
            cloudKit: cloudKit,
            appState: appState
        )

        guard profile.interestEnabled,
              profile.interestRateBps > 0,
              let rawBucket = profile.interestBucket,
              let bucket = BucketKind(rawValue: rawBucket)
        else {
            return nil
        }

        let cachedEntries = cacheService?.fetchLedgerEntries(
            profileRecordName: profile.id.recordName,
            family: family.id.recordName
        ) ?? []

        // Check-before-apply: an existing deterministic row for this month is
        // the double-run guard, independent of any caller-side state.
        let recordNameStr = Self.recordName(
            profileRecordName: profile.id.recordName,
            monthKey: Self.monthKey(for: date)
        )
        guard !cachedEntries.contains(where: { $0.recordName == recordNameStr }) else {
            return nil
        }

        let balances = BucketService(cacheService: cacheService).bucketBalances(
            profileRecordName: profile.id.recordName,
            familyRecordName: family.id.recordName
        )
        var basePennies = Int(((balances[bucket] ?? 0) * 100).rounded())
        if !profile.interestIsCompound {
            // Simple interest ignores prior credits: only deposits earn
            // interest, never interest already paid into the bucket.
            let priorInterestPennies = cachedEntries
                .filter { $0.source == Self.ledgerSource && $0.bucketKind == bucket.rawValue }
                .reduce(0) { $0 + Int(($1.amount * 100).rounded()) }
            basePennies -= priorInterestPennies
        }

        let creditPennies = Self.interestPennies(basePennies: basePennies, rateBps: profile.interestRateBps)
        guard creditPennies > 0 else { return nil }

        let entry = LedgerEntry(
            profile: CKRecord.Reference(recordID: profile.id, action: .none),
            amount: Double(creditPennies) / 100.0,
            description: Self.entryDescription,
            date: date,
            source: Self.ledgerSource,
            bucketKind: bucket.rawValue,
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: recordNameStr, zoneID: family.id.zoneID)
        )
        await cacheService?.upsertLedgerEntry(entry)
        syncCoordinator?.enqueueSave(recordID: entry.id, isOwner: appState.isZoneOwner)
        logger.info("Credited monthly interest for \(profile.id.recordName, privacy: .private) in month \(Self.monthKey(for: date), privacy: .public)")
        return entry
    }

    // MARK: - Explainer Projection

    static let ledgerSource = "interest"
    static let entryDescription = "Parent Interest"

    /// Month-by-month credits powering the plain-language explainer table.
    /// Simple keeps the principal fixed every month; compound folds each
    /// credit back in so the next month earns on it too.
    static func projectionPennies(startingPennies: Int, rateBps: Int, isCompound: Bool, months: Int) -> [Int] {
        var principalPennies = startingPennies
        var credits: [Int] = []
        for _ in 0 ..< max(0, months) {
            let credit = interestPennies(basePennies: principalPennies, rateBps: rateBps)
            credits.append(credit)
            if isCompound {
                principalPennies += credit
            }
        }
        return credits
    }
}
