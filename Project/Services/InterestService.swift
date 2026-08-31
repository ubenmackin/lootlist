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

/// Monthly savings interest engine applying compound/simple rates with deterministic IDs.
@MainActor
@Observable
final class InterestService {
    private static let staticLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "InterestService")
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "InterestService")
    private let cloudKit: any CloudKitServiceProtocol
    let cacheService: any CacheServicing
    let syncCoordinator: any SyncEnqueuing
    let appState: AppState

    init(
        cloudKit: any CloudKitServiceProtocol,
        cacheService: any CacheServicing,
        appState: AppState,
        syncCoordinator: any SyncEnqueuing
    ) {
        self.cloudKit = cloudKit
        self.cacheService = cacheService
        self.appState = appState
        self.syncCoordinator = syncCoordinator
    }

    @_disfavoredOverload
    convenience init(
        cloudKit: any CloudKitServiceProtocol,
        cacheService: (any CacheServicing)? = nil,
        appState: AppState? = nil,
        syncCoordinator: (any SyncEnqueuing)? = nil
    ) {
        final class NoopSync: SyncEnqueuing {
            func enqueueSave(recordID _: CKRecord.ID, isOwner _: Bool) {}
            func enqueueDelete(recordID _: CKRecord.ID, isOwner _: Bool) {}
            func batchEnqueueSave(recordIDs _: [CKRecord.ID], isOwner _: Bool) {}
        }
        let cache: any CacheServicing
        if let cacheService {
            cache = cacheService
        } else {
            Self.staticLogger.warning("InterestService initialized without cacheService; using fallback in-memory cache.")
            cache = CacheService.inMemoryFallback(logger: Self.staticLogger)
        }
        let state = appState ?? AppState()
        let coord: any SyncEnqueuing = syncCoordinator ?? NoopSync()
        self.init(cloudKit: cloudKit, cacheService: cache, appState: state, syncCoordinator: coord)
    }

    // MARK: - Deterministic Identity

    /// Single-source UTC month key — delegates to `WeekMath.monthKey` so
    /// interest and match flows cannot diverge on timezone handling.
    static func monthKey(for date: Date, calendar: Calendar = .iso8601UTC) -> String {
        WeekMath.monthKey(for: date, calendar: calendar)
    }

    static func recordName(profileRecordName: String, monthKey: String) -> String {
        DeterministicRecordID.interest(profileRecordName: profileRecordName, monthKey: monthKey)
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
        guard let acting = appState.currentProfile, acting.role.isParent else {
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

        await cacheService.upsertProfile(updated)
        if appState.currentProfile?.id == updated.id {
            appState.currentProfile = updated
        }
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: updated.id, appState: appState, logger: logger, context: "InterestService.updateInterestConfig")
        return updated
    }

    // MARK: - Monthly Application

    /// Whole-penny interest, always rounded down so rounding can never mint
    /// value that wasn't earned.
    static func interestPennies(basePennies: Int, rateBps: Int) -> Int {
        guard basePennies > 0, rateBps > 0 else { return 0 }
        return basePennies * rateBps / 10000
    }

    /// Applies monthly interest credit using idempotent record ID: interest-{profile}-{yyyy-MM}.
    @discardableResult
    func applyMonthlyInterest(profile: Profile,
                              family: Family,
                              date: Date = Date()) async throws -> LedgerEntry?
    {
        guard let acting = appState.currentProfile, acting.role.isParent else {
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

        let cachedEntries = cacheService.fetchLedgerEntries(
            profileRecordName: profile.id.recordName,
            family: family.id.recordName
        )

        // Check-before-apply: an existing deterministic row for this month is
        // the double-run guard, independent of any caller-side state.
        let recordNameStr = Self.recordName(
            profileRecordName: profile.id.recordName,
            monthKey: Self.monthKey(for: date)
        )
        guard !IdempotencyGuard.containsDeterministicID(recordNameStr, in: cachedEntries) else {
            return nil
        }

        let balances = BucketService(cacheService: cacheService, syncCoordinator: syncCoordinator, appState: appState).bucketBalances(
            profileRecordName: profile.id.recordName,
            familyRecordName: family.id.recordName
        )
        var basePennies = Int(((balances[bucket] ?? 0) * 100).rounded())
        if !profile.interestIsCompound {
            // Simple interest ignores prior credits: only deposits earn
            // interest, never interest already paid into the bucket.
            let priorInterestPennies = cachedEntries
                .filter { $0.sourceEnum == .interest && $0.bucketKind == bucket.rawValue }
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
            source: LedgerSource.interest.rawValue,
            bucketKind: bucket.rawValue,
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: recordNameStr, zoneID: family.id.zoneID)
        )
        await cacheService.upsertLedgerEntry(entry)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: entry.id, appState: appState, logger: logger, context: "InterestService.applyInterest")
        // WHY: Log uses CurrencyFormatter so currency render stays locale-aware and single-point.
        let formattedAmount = CurrencyFormatter.string(Double(creditPennies) / 100.0)
        logger
            .info(
                "Credited \(formattedAmount, privacy: .public) monthly interest for \(profile.id.recordName, privacy: .private) in month \(Self.monthKey(for: date), privacy: .public)"
            )
        return entry
    }

    // MARK: - Explainer Projection

    static let ledgerSource = LedgerSource.interest.rawValue
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
