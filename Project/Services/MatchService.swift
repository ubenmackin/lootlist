//
//  MatchService.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import CloudKit
import Foundation
import os

enum MatchServiceError: LocalizedError {
    case invalidConfig

    var errorDescription: String? {
        switch self {
        case .invalidConfig:
            "Pick a match rate above zero before enabling matching."
        }
    }
}

/// Parent savings match engine applying match percentages up to configured caps.
@MainActor
@Observable
final class MatchService {
    private static let staticLogger = Logger(category: "MatchService")
    private let logger = Logger(category: "MatchService")
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
        self.init(
            cloudKit: cloudKit,
            cacheService: ServiceInitHelper.resolveCacheService(provided: cacheService, logger: Self.staticLogger, serviceName: "MatchService"),
            appState: appState ?? AppState(),
            syncCoordinator: ServiceInitHelper.resolveSyncCoordinator(provided: syncCoordinator, logger: Self.staticLogger, serviceName: "MatchService")
        )
    }

    // MARK: - Deterministic Identity

    /// Single-source UTC month key — delegates to `WeekMath.monthKey` so
    /// interest and match flows cannot diverge on timezone handling.
    static func monthKey(for date: Date, calendar: Calendar = .iso8601UTC) -> String {
        WeekMath.monthKey(for: date, calendar: calendar)
    }

    static func recordName(goalRecordName: String, contributionEventID: String) -> String {
        DeterministicRecordID.match(goalRecordName: goalRecordName, contributionEventID: contributionEventID)
    }

    // MARK: - Math

    /// Whole-penny match, always rounded down so rounding can never mint value
    /// that wasn't earned. Rate can exceed 100% (rateBps > 10000) so a parent
    /// choosing a 200% match gets double the contribution.
    static func matchPennies(contributionPennies: Int64, rateBps: Int) -> Int64 {
        guard contributionPennies > 0, rateBps > 0 else { return 0 }
        return contributionPennies * Int64(rateBps) / 10000
    }

    // MARK: - Config

    /// Parent-only edit of the hero's parent-match config. Client-side role
    /// check is defense-in-depth per the authorization model; unauthorized
    /// callers get `FamilyServiceError.unauthorized`.
    @discardableResult
    func updateMatchConfig(profile: Profile,
                           enabled: Bool,
                           rateBps: Int,
                           monthlyCapPennies: Int64?) async throws -> Profile
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
            guard rateBps > 0 else {
                throw MatchServiceError.invalidConfig
            }
        }

        var updated = profile
        updated.matchEnabled = enabled
        updated.matchRateBps = max(0, rateBps)
        updated.matchMonthlyCapPennies = monthlyCapPennies.flatMap { $0 > 0 ? $0 : nil }

        await cacheService.upsertProfile(updated)
        if appState.currentProfile?.id == updated.id {
            appState.currentProfile = updated
        }
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: updated.id, appState: appState, logger: logger, context: "MatchService.updateMatchSettings")
        return updated
    }

    // MARK: - Match Application

    /// Applies parent match using idempotent record ID: match-{goal}-{sourceEventID}.
    @discardableResult
    func applyMatch(for goal: Goal,
                    contributionEventID: String,
                    contributionAmount: Int64,
                    date: Date = Date(),
                    heroProfile: Profile,
                    family: Family) async throws -> LedgerEntry?
    {
        guard let acting = appState.currentProfile, acting.role.isParent else {
            throw FamilyServiceError.unauthorized
        }
        guard contributionAmount > 0,
              heroProfile.matchEnabled,
              heroProfile.matchRateBps > 0,
              goal.bucketKind == BucketKind.longTermSave.rawValue
        else {
            return nil
        }
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            family: family,
            cloudKit: cloudKit,
            appState: appState
        )

        let recordNameStr = Self.recordName(
            goalRecordName: goal.id.recordName,
            contributionEventID: contributionEventID
        )

        // Check-before-apply: an existing deterministic row for this
        // contribution is the double-run guard, independent of any
        // caller-side state.
        let cachedEntries = cacheService.fetchLedgerEntries(
            profileRecordName: heroProfile.id.recordName,
            family: family.id.recordName
        )
        guard !IdempotencyGuard.containsDeterministicID(recordNameStr, in: cachedEntries) else {
            return nil
        }

        // Derive month-to-date matched by scanning existing match
        // entries whose date falls in the same calendar month.
        let month = Self.monthKey(for: date)
        let monthStart = WeekMath.monthStart(for: date)
        let monthEnd = WeekMath.monthEnd(for: date)
        let mtdPennies = cachedEntries
            .filter { entry in
                guard entry.sourceEnum == .match else { return false }
                let entryDate = WeekMath.startOfDay(for: entry.date)
                return entryDate >= monthStart && entryDate < monthEnd
            }
            .reduce(into: Int64(0)) { $0 += $1.amount }

        var matchPennies = Self.matchPennies(
            contributionPennies: contributionAmount,
            rateBps: heroProfile.matchRateBps
        )

        // Enforce monthly cap when configured. Cap is denominated in
        // pennies (same unit as match calculations) so the comparison
        // stays exact without floating-point rounding.
        if let cap = heroProfile.matchMonthlyCapPennies, cap > 0 {
            let remaining = max(cap - mtdPennies, 0)
            matchPennies = min(matchPennies, remaining)
        }

        guard matchPennies > 0 else { return nil }

        let entry = LedgerEntry(
            profile: CKRecord.Reference(recordID: heroProfile.id, action: .none),
            amount: matchPennies,
            description: Self.entryDescription,
            date: date,
            source: LedgerSource.match.rawValue,
            bucketKind: BucketKind.longTermSave.rawValue,
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: recordNameStr, zoneID: family.id.zoneID)
        )
        await cacheService.upsertLedgerEntry(entry)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: entry.id, appState: appState, logger: logger, context: "MatchService.applyMatch")
        let formattedAmount = CurrencyFormatter.string(pennies: matchPennies)
        logger.info("Matched \(formattedAmount, privacy: .public) for goal \(goal.id.recordName, privacy: .private) in month \(month, privacy: .public)")
        return entry
    }

    // MARK: - Constants

    static let ledgerSource = LedgerSource.match.rawValue
    static let entryDescription = "Parent Match"
}
