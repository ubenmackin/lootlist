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
    /// deterministic `period-<family>-<profile>-<week>` record name. Two
    /// quest completions in the same week would otherwise both observe nil
    /// and create competing rows with identical record names, leaving
    /// `totalEarned` / `questsCompleted` indeterminate after the race
    /// through cache upsert and `enqueueSave`.
    private let periodCreationLocks = PeriodMutex()

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
    /// CloudKit when `CacheService.isCacheFresh` is false. Gold proration
    /// delegates to `GoldCalculation.totalCredit` via `sumGold`.
    ///
    /// - Throws: `CloudKitServiceError` / `CKError` when `sumGold`'s batched
    ///   quest fetch fails, or when `fetchQuestLogs` / `fetchAssignedQuests` /
    ///   `fetchLedgerEntries` requires a CloudKit round trip that fails.
    ///   Transient failures are **re-thrown** (never `try?` → `0`) so callers
    ///   surface the failure instead of silently under-crediting the wallet.
    ///   UI callers (ViewModels / Views) must invoke with `do { _ = try await
    ///   treasury.weeklyBreakdown(...) } catch { toast + retry }` — a hanging
    ///   `ProgressView` or an uncaught throw that crashes the view hierarchy
    ///   is a contract violation. `TreasuryViewModel.refreshWeeklyBreakdown`,
    ///   `FamilyDashboardViewModel.refreshWeekSummary`, and
    ///   `QuestService.earnedThisWeek` document the view-model side of this
    ///   contract.
    func weeklyBreakdown(profile: Profile,
                         family: Family,
                         weekOf: Date) async throws -> WeeklyBreakdown
    {
        let startOfWeek = WeekMath.startOfWeek(for: weekOf, payoutDay: profile.payoutDay ?? family.payoutDay)
        let weekRange = TreasuryService.weekRange(starting: startOfWeek)
        let logs = try await fetchQuestLogs(profile: profile,
                                            weekStarting: startOfWeek,
                                            weekEnding: weekRange.upperBound)
        var goldFromQuests = try await sumGold(for: logs, family: family)
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

        // Serialize the fetch-or-create critical section per deterministic
        // period record name. Without this, two concurrent settlements for
        // the same hero/week can both observe nil and create duplicate
        // AllowancePeriod rows with identical record names.
        try await periodCreationLocks.lock(key: periodRecordName)
        defer { periodCreationLocks.unlock(key: periodRecordName) }

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

        // Cache-first profile/family resolution mirrors QuestService's
        // settlement hot path: serve the family's cached records when fresh
        // (no CloudKit round-trip), else fall through to a single fetch.
        // Throw contract: `weeklyBreakdown` rethrows on `GoldCalculation.totalCredit`
        // fetch failures rather than silently under-crediting. This helper is
        // intentionally tolerant — a transient breakdown failure falls back to the
        // caller-supplied `totalEarned` / `questsCompleted` so an in-flight
        // settlement never hangs the wallet — but the failure is still surfaced
        // via `logger` + `ToastManager` with a retry affordance, consistent with
        // `processRealTimeSettlement`'s `do/catch` in `QuestService.applyReward`.
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
            await mintPayoutLedgerEntry(
                periodRecordName: period.id.recordName,
                amount: updated.paidAmount ?? questGoldToPayout,
                weekOf: period.weekOf,
                profile: period.profile,
                family: period.family,
                date: updated.paidDate ?? Date()
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
    /// `weeklyBreakdown`, `fetchQuestLogs`, `sumGold` — **throws** on
    /// transient failure (see `GoldCalculation.totalCredit`'s documented
    /// throw contract) and callers must handle with `do/catch` + toast + retry
    /// rather than letting the throw hang the UI. The canonical caller is
    /// `QuestService.applyReward`, which wraps this in a detached `Task` with
    /// `logger.error` + `toastManager.show` so the wallet never appears to hang
    /// and the error is consistently surfaced (mirroring `updateAllowance`'s
    /// tolerant `do/catch` + toast fallback).
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

        let breakdown = try await weeklyBreakdown(profile: profile, family: family, weekOf: weekOf)

        let logs = try await fetchQuestLogs(profile: profile,
                                            weekStarting: weekOf,
                                            weekEnding: TreasuryService.weekRange(starting: weekOf).upperBound)
        let questGold = try await sumGold(for: logs, family: family)

        var updated = period
        updated.paidAmount = max(period.paidAmount ?? 0, questGold)
        updated.paidDate = Date()
        let amountChanged: Bool = {
            if let previous = period.paidAmount, let current = updated.paidAmount {
                return abs(previous - current) > 0.001
            }
            return period.paidAmount != updated.paidAmount
        }()
        if amountChanged {
            let saved = try await updateAllowance(period: updated,
                                                  totalEarned: questGold,
                                                  questsCompleted: breakdown.questsCount)

            await mintRealTimeLedgerEntry(
                periodRecordName: period.id.recordName,
                amount: questGold,
                weekOf: weekOf,
                profile: period.profile,
                family: CKRecord.Reference(recordID: family.id, action: .none),
                date: Date()
            )

            return saved
        }
        let saved = try await updateAllowance(period: updated,
                                              totalEarned: questGold,
                                              questsCompleted: breakdown.questsCount)

        // Upsert the real-time quest-earnings ledger entry. The record name
        // is derived from the period so each settlement upserts the same
        // row with the cumulative amount.
        await mintRealTimeLedgerEntry(
            periodRecordName: period.id.recordName,
            amount: questGold,
            weekOf: weekOf,
            profile: period.profile,
            family: CKRecord.Reference(recordID: family.id, action: .none),
            date: Date()
        )

        return saved
    }

    // MARK: - Ledger Minting

    /// Idempotent payout ledger mint using "payout-<periodRecordName>" as the record name.
    private func mintPayoutLedgerEntry(
        periodRecordName: String,
        amount: Double,
        weekOf: Date,
        profile: CKRecord.Reference,
        family: CKRecord.Reference,
        date: Date
    ) async {
        guard amount > 0 else { return }
        let entryRecordName = "payout-\(periodRecordName)"
        let rtRecordName = "rt-\(periodRecordName)"
        if let cache = cacheService {
            let cachedEntries = cache.fetchLedgerEntries(profileRecordName: profile.recordID.recordName, family: family.recordID.recordName)
            if cachedEntries.first(where: { $0.recordName == entryRecordName }) != nil {
                return
            }
            if cachedEntries.first(where: { $0.recordName == rtRecordName }) != nil {
                return
            }

            if let cachedPeriod = cache.fetchAllowancePeriod(recordName: periodRecordName, family: family.recordID.recordName) {
                guard cachedPeriod.statusEnum == .paid, abs((cachedPeriod.paidAmount ?? 0.0) - amount) < 0.001 else {
                    logger.warning("Skipping payout ledger minting: period \(periodRecordName) status is not paid or amount mismatch")
                    return
                }
            }
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let entry = LedgerEntry(
            profile: profile,
            amount: abs(amount),
            description: "Quest earnings (week of \(formatter.string(from: weekOf)))",
            date: date,
            source: "quest",
            family: family,
            id: CKRecord.ID(recordName: entryRecordName, zoneID: family.recordID.zoneID)
        )
        cacheService?.upsertLedgerEntry(entry)
        let isOwner = appState?.isZoneOwner ?? false
        syncCoordinator?.enqueueSave(recordID: entry.id, isOwner: isOwner)
    }

    private func mintRealTimeLedgerEntry(
        periodRecordName: String,
        amount: Double,
        weekOf: Date,
        profile: CKRecord.Reference,
        family: CKRecord.Reference,
        date: Date
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
        let isOwner = appState?.isZoneOwner ?? false
        syncCoordinator?.enqueueSave(recordID: entry.id, isOwner: isOwner)
    }
}

// MARK: - PeriodMutex

/// Per-key async mutex that serializes callers contending on the same
/// deterministic period record name while allowing different periods to
/// proceed in parallel. Uses `Synchronization.Mutex` to protect the
/// locked-key set and waiter queues so `unlock` can be called
/// synchronously from `defer` inside `getOrCreateAllowancePeriod`.
private final class PeriodMutex: Sendable {
    private final class Box: @unchecked Sendable {
        var continuation: CheckedContinuation<Void, Error>?
    }

    private struct State {
        var locked = Set<String>()
        var waiters: [String: [Box]] = [:]
    }

    private let state = Mutex<State>(State())

    /// Acquires the lock for `key`. If the key is already held, the
    /// caller suspends until the current holder releases it. Ownership
    /// is transferred directly to the next waiter on `unlock`.
    /// The waiter is appended atomically inside the same `withLock` that
    /// decides to wait, closing the TOCTOU between check and enqueue.
    /// Cancellation removes the waiter and resumes throwing
    /// `CancellationError` so a cancelled task never holds the lock.
    func lock(key: String) async throws {
        let box = Box()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                box.continuation = continuation
                let didAcquire = state.withLock { state -> Bool in
                    if state.locked.contains(key) {
                        state.waiters[key, default: []].append(box)
                        return false
                    }
                    state.locked.insert(key)
                    return true
                }
                if didAcquire {
                    box.continuation = nil
                    continuation.resume()
                }
            }
        }, onCancel: {
            var toResume: CheckedContinuation<Void, Error>?
            state.withLock { state in
                guard var queue = state.waiters[key] else { return }
                if let idx = queue.firstIndex(where: { $0 === box }) {
                    let removed = queue.remove(at: idx)
                    toResume = removed.continuation
                    removed.continuation = nil
                    if queue.isEmpty {
                        state.waiters.removeValue(forKey: key)
                    } else {
                        state.waiters[key] = queue
                    }
                }
            }
            toResume?.resume(throwing: CancellationError())
        })
    }

    /// Releases the lock for `key`, resuming the next waiter if present
    /// and transferring ownership, otherwise clearing the locked flag.
    func unlock(key: String) {
        var next: CheckedContinuation<Void, Error>?
        state.withLock { state in
            if var queue = state.waiters[key], !queue.isEmpty {
                let box = queue.removeFirst()
                next = box.continuation
                box.continuation = nil
                if queue.isEmpty {
                    state.waiters.removeValue(forKey: key)
                } else {
                    state.waiters[key] = queue
                }
                // Ownership stays with the resumed waiter; keep `locked`.
            } else {
                state.locked.remove(key)
            }
        }
        next?.resume()
    }
}
