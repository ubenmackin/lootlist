//
//  TreasuryService.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import os
import Synchronization

@MainActor
@Observable
final class TreasuryService {
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "TreasuryService")
    let cloudKit: any CloudKitServiceProtocol
    let notificationService: NotificationService?
    var cacheService: CacheService?
    var syncCoordinator: CKSyncEngineCoordinator?

    /// Guards against concurrent settlement of the same period.
    private let inFlightSettlements = Mutex<Set<String>>([])

    // MARK: - Period Creation Serialization

    /// Serializes concurrent `getOrCreateAllowancePeriod` calls for the same
    /// deterministic `period-<family>-<profile>-<week>` record name via
    /// `GemLock`. Two quest completions in the same week would otherwise
    /// both observe nil and create competing rows with identical record names.
    private let periodLock = GemLock()

    /// The active session's app state, used to resolve the acting profile for
    /// privileged payout finalization. Wired by `AppDependencies`; optional so
    /// read-only callers (tests, real-time settlement) need not set it.
    var appState: AppState?

    let toastManager: ToastManager?

    init(
        cloudKit: any CloudKitServiceProtocol,
        notificationService: NotificationService? = nil,
        cacheService: CacheService? = nil,
        toastManager: ToastManager? = nil,
        appState: AppState? = nil,
        syncCoordinator: CKSyncEngineCoordinator? = nil
    ) {
        self.cloudKit = cloudKit
        self.notificationService = notificationService
        self.cacheService = cacheService
        self.appState = appState
        self.toastManager = toastManager
        self.syncCoordinator = syncCoordinator
    }

    // MARK: - Balance & Weekly Breakdown

    func currentBalance(for profile: Profile) async throws -> Double {
        let ledgerEntries = try await fetchAllLedgerEntries(profile: profile)
        return ledgerEntries.reduce(0.0) { $0 + $1.amount }
    }

    struct WeeklyBreakdown: Equatable, Sendable {
        var questsCount: Int = 0

        var goldFromQuests: Double = 0

        var bonusGold: Double = 0

        var totalEarned: Double = 0

        var spent: Double = 0

        var net: Double = 0

        var payoutStatus: PayoutStatus?
        var paidAmount: Double?
    }

    /// Wallet-week gold breakdown for a single hero. Cache-first for
    /// quest logs / assigned quests / ledger entries; falls through to
    /// CloudKit when `CacheService.isCacheFresh` is false. Gold proration is
    /// pure `GoldCalculation` math over already-fetched quests.
    ///
    /// - Throws: `CloudKitServiceError` / `CKError` when `fetchQuestLogs` /
    ///   `fetchAssignedQuests` / `fetchLedgerEntries` requires a CloudKit
    ///   round trip that fails. Transient failures are re-thrown so callers
    ///   surface the failure instead of silently under-crediting the wallet.
    ///   UI callers must invoke with `do { _ = try await
    ///   treasury.weeklyBreakdown(...) } catch { toast + retry }`.
    func weeklyBreakdown(profile: Profile,
                         family: Family,
                         weekOf: Date) async throws -> WeeklyBreakdown
    {
        let startOfWeek = WeekMath.startOfWeek(for: weekOf, payoutDay: profile.payoutDay ?? family.payoutDay)
        let weekRange = TreasuryService.weekRange(starting: startOfWeek)
        let logs = try await fetchQuestLogs(profile: profile,
                                            weekStarting: startOfWeek,
                                            weekEnding: weekRange.upperBound)
        let quests = try await fetchQuestsForGold(family: family, logs: logs)
        var goldFromQuests = sumGold(for: logs, quests: quests)
        let completedCount = logs.filter { TreasuryService.isCompleted($0) }.count

        let effectivePolicy = effectivePayoutPolicy(for: profile, family: family)
        if effectivePolicy == .allOrNothing {
            let assigned = try await fetchAssignedQuests(profile: profile, family: family, weekOf: startOfWeek)
            if !assigned.isEmpty {
                let approvedLogsScoped = logs.filter { $0.verificationStatus == .verified || $0.verificationStatus == .autoApproved }
                // Use recordName equality — CKRecord.ID equality includes zoneID (ownerName)
                // so a quest fetched from private vs shared zone would otherwise
                // fail the comparison and incorrectly zero the all-or-nothing payout.
                let fullyCompletedCount = assigned.filter { quest in
                    let questLogs = approvedLogsScoped.filter { $0.quest.recordID.recordName == quest.id.recordName }
                    return GoldCalculation.isFullyCompleted(quest: quest, approvedCount: questLogs.count)
                }.count
                if fullyCompletedCount < assigned.count {
                    goldFromQuests = 0.0
                }
            }
        }

        let ledgerEntries = try await fetchLedgerEntries(
            profile: profile, in: weekRange
        )
        let bonusGold = ledgerEntries
            .filter { $0.amount > 0 && $0.source != "quest" }
            .reduce(0.0) { $0 + $1.amount }
        let spent = ledgerEntries
            .filter { $0.amount < 0 }
            .reduce(0.0) { $0 + $1.amount }

        let totalEarned = goldFromQuests + bonusGold
        return WeeklyBreakdown(
            questsCount: completedCount,
            goldFromQuests: goldFromQuests,
            bonusGold: bonusGold,
            totalEarned: totalEarned,
            spent: abs(spent),
            net: totalEarned + spent
        )
    }

    // MARK: - Allowance Periods

    func getOrCreateAllowancePeriod(profile: Profile,
                                    weekOf: Date,
                                    family: Family) async throws -> AllowancePeriod
    {
        guard let appState, let acting = appState.currentProfile,
              acting.id == profile.id || acting.role.isParent
        else {
            throw FamilyServiceError.unauthorized
        }
        guard profile.family.recordID == family.id,
              profile.id.zoneID == family.id.zoneID
        else {
            throw FamilyServiceError.unauthorized
        }
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            family: family,
            cloudKit: cloudKit,
            appState: appState
        )

        let effectivePayoutDay = profile.payoutDay ?? family.payoutDay
        let startOfWeek = WeekMath.startOfWeek(for: weekOf, payoutDay: effectivePayoutDay)
        let periodRecordName = "period-\(family.id.recordName)-\(profile.id.recordName)-\(Int(startOfWeek.timeIntervalSince1970))"

        return try await periodLock.withLock(key: periodRecordName) {
            // Fast cache existence check that bypasses the `isCacheFresh` gate.
            // The cache upsert from the first holder is visible immediately even
            // when the freshness watermark is stale; `fetchAllowancePeriod` would
            // otherwise discard the cached row and re-query CloudKit, missing the
            // just-created local row and creating a duplicate.
            if let cache = cacheService,
               let cached = cache.fetchAllowancePeriod(recordName: periodRecordName, family: family.id.recordName)
            {
                return cached.toAllowancePeriod(zoneID: family.id.zoneID)
            }

            if let existing = try await fetchAllowancePeriod(profile: profile, weekOf: startOfWeek) {
                return existing
            }

            return try await createPeriod(profile: profile, family: family, weekOf: startOfWeek)
        }
    }

    private func createPeriod(profile: Profile, family: Family, weekOf: Date) async throws -> AllowancePeriod {
        guard let appState, let acting = appState.currentProfile,
              acting.id == profile.id || acting.role.isParent
        else {
            throw FamilyServiceError.unauthorized
        }
        guard profile.family.recordID == family.id,
              profile.id.zoneID == family.id.zoneID
        else {
            throw FamilyServiceError.unauthorized
        }
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            family: family,
            cloudKit: cloudKit,
            appState: appState
        )

        let effectivePayoutDay = profile.payoutDay ?? family.payoutDay
        let startOfWeek = WeekMath.startOfWeek(for: weekOf, payoutDay: effectivePayoutDay)
        let logs = try await fetchQuestLogs(profile: profile,
                                            weekStarting: startOfWeek,
                                            weekEnding: TreasuryService
                                                .weekRange(starting: startOfWeek).upperBound)
        let completedCount = logs.filter { TreasuryService.isCompleted($0) }.count

        let period = AllowancePeriod(
            weekOf: startOfWeek,
            profile: CKRecord.Reference(recordID: profile.id, action: .none),
            questsTotal: completedCount,
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(
                recordName: "period-\(family.id.recordName)-\(profile.id.recordName)-\(Int(startOfWeek.timeIntervalSince1970))",
                zoneID: family.id.zoneID
            )
        )

        cacheService?.upsertAllowancePeriod(period)
        let isOwner = appState.isZoneOwner
        syncCoordinator?.enqueueSave(recordID: period.id, isOwner: isOwner)
        return period
    }

    func updateAllowance(period: AllowancePeriod,
                         totalEarned: Double? = nil,
                         questsCompleted: Int? = nil,
                         questsTotal: Int? = nil) async throws -> AllowancePeriod
    {
        guard let appState, let acting = appState.currentProfile,
              acting.id == period.profile.recordID || acting.role.isParent
        else {
            throw FamilyServiceError.unauthorized
        }
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            familyRef: period.family,
            zoneID: period.id.zoneID,
            appState: appState,
            cloudKit: cloudKit
        )

        var updated = period

        // Resolve profile/family cache-first and compute breakdown.
        do {
            let profile = try await resolveProfile(recordID: period.profile.recordID, familyRecordName: period.family.recordID.recordName)
            let family = try await resolveFamily(recordID: period.family.recordID)
            let breakdown = try await weeklyBreakdown(profile: profile,
                                                      family: family,
                                                      weekOf: period.weekOf)
            updated.totalEarned = totalEarned ?? breakdown.totalEarned
            updated.questsCompleted = questsCompleted ?? breakdown.questsCount
        } catch {
            logger.warning("Could not resolve payout context for period update: \(error, privacy: .private)")
            toastManager?.show(message: "Could not refresh wallet totals. Pull to retry.", type: .warning)
            if let totalEarned {
                updated.totalEarned = totalEarned
            }
            if let questsCompleted {
                updated.questsCompleted = questsCompleted
            }
        }
        if let questsTotal {
            updated.questsTotal = questsTotal
        }

        cacheService?.upsertAllowancePeriod(updated)
        let isOwner = appState.isZoneOwner
        syncCoordinator?.enqueueSave(recordID: updated.id, isOwner: isOwner)
        return updated
    }

    // MARK: - Payout & Settlement

    func runPayout(period: AllowancePeriod) async throws {
        guard let appState, let acting = appState.currentProfile,
              acting.role.isParent
        else {
            throw FamilyServiceError.unauthorized
        }

        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            familyRef: period.family,
            zoneID: period.id.zoneID,
            appState: appState,
            cloudKit: cloudKit
        )

        let periodRecordName = period.id.recordName
        let inserted = inFlightSettlements.withLock { $0.insert(periodRecordName).inserted }
        guard inserted else {
            logger.debug("Period payout already in flight for \(periodRecordName, privacy: .private), skipping.")
            return
        }
        defer { inFlightSettlements.withLock { _ = $0.remove(periodRecordName) } }

        guard period.status != .paid else {
            logger.debug("Period already paid, skipping payout.")
            return
        }

        var updated = period

        var resolvedProfile: Profile?
        var resolvedFamily: Family?
        var questGoldToPayout = 0.0
        do {
            let profile = try await resolveProfile(recordID: period.profile.recordID, familyRecordName: period.family.recordID.recordName)
            let family = try await resolveFamily(recordID: period.family.recordID)
            resolvedProfile = profile
            resolvedFamily = family
            let breakdown = try await weeklyBreakdown(profile: profile, family: family, weekOf: period.weekOf)
            guard breakdown.totalEarned > 0 else {
                // Even when nothing was earned this week the period must still
                // be closed as paid with zero — otherwise the week stays
                // open and the auto-payout coordinator retries it on every
                // launch, foreground transition, and background refresh.
                updated.status = .paid
                updated.paidDate = Date()
                updated.paidAmount = 0
                updated.totalEarned = breakdown.totalEarned
                updated.questsCompleted = breakdown.questsCount
                cacheService?.upsertAllowancePeriod(updated)
                let isOwner = appState.isZoneOwner
                syncCoordinator?.enqueueSave(recordID: updated.id, isOwner: isOwner)
                return
            }
            updated.totalEarned = breakdown.totalEarned
            updated.questsCompleted = breakdown.questsCount
            questGoldToPayout = breakdown.goldFromQuests
        } catch {
            logger.warning("Could not resolve payout context for period payout: \(error, privacy: .private)")
            throw error
        }

        updated.status = .paid
        updated.paidDate = Date()
        updated.paidAmount = questGoldToPayout

        cacheService?.upsertAllowancePeriod(updated)
        let isOwner = appState.isZoneOwner
        syncCoordinator?.enqueueSave(recordID: updated.id, isOwner: isOwner)

        let effectivePolicy = resolvedProfile.map { effectivePayoutPolicy(for: $0, family: resolvedFamily) } ?? resolvedFamily?.payoutPolicy ?? .perQuest
        if effectivePolicy != .realTime {
            await mintBucketSplitPayout(
                periodRecordName: period.id.recordName,
                amount: updated.paidAmount ?? questGoldToPayout,
                weekOf: period.weekOf,
                profile: resolvedProfile,
                family: period.family,
                date: updated.paidDate ?? Date(),
                isOwner: appState.isZoneOwner
            )
        }

        if let notificationService {
            Task { [logger] in
                do {
                    let profile = try await resolveProfile(recordID: period.profile.recordID, familyRecordName: period.family.recordID.recordName)
                    let family = try await resolveFamily(recordID: period.family.recordID)
                    try await notificationService.sendWeeklySummary(to: profile, family: family, weekOf: period.weekOf)
                } catch {
                    logger.error("Failed to send weekly summary notification: \(error, privacy: .private)")
                }
            }
        }
    }

    /// Process real-time settlement for heroes with `.realTime` payout policy.
    ///
    /// Auth / scope guards return `nil` (not `throw`) so a benign
    /// unauthorized or out-of-scope call is a no-op rather than a wallet
    /// error. All CloudKit-backed work — `getOrCreateAllowancePeriod`,
    /// `fetchQuestLogs` — throws on transient failure and callers must
    /// handle with `do/catch` + toast + retry rather than letting the throw
    /// hang the UI. The canonical caller is `QuestService.applyReward`,
    /// which wraps this in a detached `Task` with `logger.error` +
    /// `toastManager.show` so the wallet never appears to hang.
    /// Gold proration itself is pure `GoldCalculation` math over already-fetched quests.
    @discardableResult
    func processRealTimeSettlement(profile: Profile, family: Family, date: Date = Date()) async throws -> AllowancePeriod? {
        guard let appState, let acting = appState.currentProfile,
              acting.id == profile.id || acting.role.isParent
        else {
            logger.warning("processRealTimeSettlement aborted: acting profile unauthorized for \(profile.id.recordName, privacy: .private)")
            return nil
        }
        guard profile.family.recordID == family.id,
              profile.id.zoneID == family.id.zoneID
        else {
            logger.warning("processRealTimeSettlement aborted: profile family or zone mismatch for \(profile.id.recordName, privacy: .private)")
            return nil
        }

        do {
            try ActiveFamilyScopeGuard.requireActiveFamilyScope(
                family: family,
                cloudKit: cloudKit,
                appState: appState
            )
        } catch {
            logger.warning("processRealTimeSettlement aborted due to scope violation: \(error, privacy: .private)")
            return nil
        }

        let effectivePolicy = effectivePayoutPolicy(for: profile, family: family)
        guard effectivePolicy == .realTime else { return nil }
        let weekOf = WeekMath.startOfWeek(for: date, payoutDay: profile.payoutDay ?? family.payoutDay)
        let periodRecordName = "period-\(family.id.recordName)-\(profile.id.recordName)-\(Int(weekOf.timeIntervalSince1970))"
        let inserted = inFlightSettlements.withLock { $0.insert(periodRecordName).inserted }
        guard inserted else {
            return nil
        }
        defer { inFlightSettlements.withLock { _ = $0.remove(periodRecordName) } }

        let period = try await getOrCreateAllowancePeriod(profile: profile, weekOf: weekOf, family: family)

        // Single snapshot for quest logs and gold — prevents divergence
        // between quest count and earned amount if the SwiftData cache
        // changes between separate async fetches.
        let logs = try await fetchQuestLogs(profile: profile,
                                            weekStarting: weekOf,
                                            weekEnding: TreasuryService.weekRange(starting: weekOf).upperBound)
        let quests = try await fetchQuestsForGold(family: family, logs: logs)
        let questGold = sumGold(for: logs, quests: quests)
        let questsCount = logs.filter { TreasuryService.isCompleted($0) }.count

        var updated = period
        updated.paidAmount = max(period.paidAmount ?? 0, questGold)
        updated.paidDate = Date()
        // Single persistence point — totalEarned / questsCompleted are always
        // reconciled from the live quest snapshot regardless of whether
        // paidAmount moved, so one call covers both cases.
        let saved = try await updateAllowance(period: updated,
                                              totalEarned: questGold,
                                              questsCompleted: questsCount)

        await mintRealTimeLedgerEntry(
            periodRecordName: period.id.recordName,
            amount: questGold,
            weekOf: weekOf,
            profile: period.profile,
            family: CKRecord.Reference(recordID: family.id, action: .none),
            date: Date(),
            isOwner: appState.isZoneOwner
        )

        return saved
    }

    // MARK: - Ledger Minting

    private func mintRealTimeLedgerEntry(
        periodRecordName: String,
        amount: Double,
        weekOf: Date,
        profile: CKRecord.Reference,
        family: CKRecord.Reference,
        date: Date,
        isOwner: Bool
    ) async {
        guard amount > 0 else { return }
        let entryRecordName = "rt-\(periodRecordName)"
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let entry = LedgerEntry(
            profile: profile,
            amount: abs(amount),
            description: "Quest earnings — real-time (week of \(formatter.string(from: weekOf)))",
            date: date,
            source: "quest",
            family: family,
            id: CKRecord.ID(recordName: entryRecordName, zoneID: family.recordID.zoneID)
        )
        cacheService?.upsertLedgerEntry(entry)
        syncCoordinator?.enqueueSave(recordID: entry.id, isOwner: isOwner)
    }
}
