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
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "MatchService")
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
    /// deterministic month boundary for the cap check or they could overmatch.
    static func monthKey(for date: Date, calendar: Calendar = .iso8601UTC) -> String {
        let components = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }

    static func recordName(goalRecordName: String, contributionEventID: String) -> String {
        "match-\(goalRecordName)-\(contributionEventID)"
    }

    // MARK: - Math

    /// Whole-penny match, always rounded down so rounding can never mint value
    /// that wasn't earned. Rate can exceed 100% (rateBps > 10000) so a parent
    /// choosing a 200% match gets double the contribution.
    static func matchPennies(contributionPennies: Int, rateBps: Int) -> Int {
        guard contributionPennies > 0, rateBps > 0 else { return 0 }
        return contributionPennies * rateBps / 10000
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
            guard rateBps > 0 else {
                throw MatchServiceError.invalidConfig
            }
        }

        var updated = profile
        updated.matchEnabled = enabled
        updated.matchRateBps = max(0, rateBps)
        updated.matchMonthlyCapPennies = monthlyCapPennies.flatMap { $0 > 0 ? $0 : nil }

        await cacheService?.upsertProfile(updated)
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
                    contributionAmount: Double,
                    date: Date = Date(),
                    heroProfile: Profile,
                    family: Family) async throws -> LedgerEntry?
    {
        guard let appState, let acting = appState.currentProfile, acting.role.isParent else {
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
        let cachedEntries = cacheService?.fetchLedgerEntries(
            profileRecordName: heroProfile.id.recordName,
            family: family.id.recordName
        ) ?? []
        guard !cachedEntries.contains(where: { $0.recordName == recordNameStr }) else {
            return nil
        }

        // Derive month-to-date matched by scanning existing match
        // entries whose date falls in the same calendar month.
        let month = Self.monthKey(for: date)
        let monthStart = monthStart(for: date)
        let monthEnd = monthEnd(for: date)
        let mtdPennies = cachedEntries
            .filter { entry in
                guard entry.sourceEnum == .match else { return false }
                guard let entryDate = Calendar.iso8601UTC.date(
                    from: Calendar.iso8601UTC.dateComponents([.year, .month, .day], from: entry.date)
                ) else { return false }
                return entryDate >= monthStart && entryDate < monthEnd
            }
            .reduce(into: 0) { $0 += Int(($1.amount * 100).rounded()) }

        let contributionPennies = Int((contributionAmount * 100).rounded())
        var matchPennies = Self.matchPennies(
            contributionPennies: contributionPennies,
            rateBps: heroProfile.matchRateBps
        )

        // Enforce monthly cap when configured. Cap is denominated in
        // pennies (same unit as match calculations) so the comparison
        // stays exact without floating-point rounding.
        if let cap = heroProfile.matchMonthlyCapPennies, cap > 0 {
            let remaining = max(Int(cap) - mtdPennies, 0)
            matchPennies = min(matchPennies, remaining)
        }

        guard matchPennies > 0 else { return nil }

        let entry = LedgerEntry(
            profile: CKRecord.Reference(recordID: heroProfile.id, action: .none),
            amount: Double(matchPennies) / 100.0,
            description: Self.entryDescription,
            date: date,
            source: LedgerSource.match.rawValue,
            bucketKind: BucketKind.longTermSave.rawValue,
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: recordNameStr, zoneID: family.id.zoneID)
        )
        await cacheService?.upsertLedgerEntry(entry)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: entry.id, appState: appState, logger: logger, context: "MatchService.applyMatch")
        // WHY: Log uses CurrencyFormatter so currency render stays locale-aware and single-point.
        let formattedAmount = CurrencyFormatter.string(Double(matchPennies) / 100.0)
        logger.info("Matched \(formattedAmount, privacy: .public) for goal \(goal.id.recordName, privacy: .private) in month \(month, privacy: .public)")
        return entry
    }

    // MARK: - Constants

    static let ledgerSource = LedgerSource.match.rawValue
    static let entryDescription = "Parent Match"

    // MARK: - Helpers

    private func monthStart(for date: Date) -> Date {
        let parts = Calendar.iso8601UTC.dateComponents([.year, .month], from: date)
        var comps = DateComponents()
        comps.year = parts.year
        comps.month = parts.month
        comps.day = 1
        comps.hour = 0
        comps.minute = 0
        comps.second = 0
        return Calendar.iso8601UTC.date(from: comps) ?? date
    }

    private func monthEnd(for date: Date) -> Date {
        let parts = Calendar.iso8601UTC.dateComponents([.year, .month], from: date)
        var startComps = DateComponents()
        startComps.year = parts.year
        startComps.month = parts.month
        startComps.day = 1
        startComps.hour = 0
        startComps.minute = 0
        startComps.second = 0
        guard let start = Calendar.iso8601UTC.date(from: startComps),
              let end = Calendar.iso8601UTC.date(byAdding: .month, value: 1, to: start)
        else { return date }
        return end
    }
}
