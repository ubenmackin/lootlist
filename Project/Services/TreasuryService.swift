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
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "TreasuryService")
    private let cloudKit: any CloudKitServiceProtocol
    let notificationService: NotificationService?
    var cacheService: CacheService?
    var syncCoordinator: CKSyncEngineCoordinator?

    /// In-flight settlement lock per period to prevent concurrent real-time settlement races.
    private let inFlightSettlements = Mutex<Set<String>>([])

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

        if profile.payoutPolicy == .allOrNothing {
            let assigned = try await fetchAssignedQuests(profile: profile, family: family, weekOf: startOfWeek)
            if !assigned.isEmpty {
                let approvedLogsScoped = logs.filter { $0.verificationStatus == .verified || $0.verificationStatus == .autoApproved }
                let fullyCompletedCount = assigned.filter { quest in
                    let questLogs = approvedLogsScoped.filter { $0.quest.recordID == quest.id }
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
        // Internal settlement helper: actor must own the period (hero
        // self-settlement) or be a parent (parent override).
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

    func runPayout(period: AllowancePeriod) async throws {
        // Privileged mutation: finalizing a hero's payout is parent-only.
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

        guard period.status != .paid else {
            logger.debug("Period already paid, skipping payout.")
            return
        }

        var updated = period

        var resolvedProfile: Profile?
        var questGoldToPayout = 0.0
        do {
            let profile = try await resolveProfile(recordID: period.profile.recordID, familyRecordName: period.family.recordID.recordName)
            let family = try await resolveFamily(recordID: period.family.recordID)
            resolvedProfile = profile
            let breakdown = try await weeklyBreakdown(profile: profile, family: family, weekOf: period.weekOf)
            guard breakdown.totalEarned > 0 else {
                return
            }
            updated.totalEarned = breakdown.totalEarned
            updated.questsCompleted = breakdown.questsCount
            questGoldToPayout = breakdown.goldFromQuests
        } catch {
            logger.warning("Could not resolve payout context for period payout: \(error, privacy: .private)")
            // Abort instead of falling back to stale cached totals. Silently
            // using a stale totalEarned and marking the period .paid can mint
            // an incorrect payout during a transient resolution failure. The
            // caller (AutoPayoutCoordinator) will retry on next activation.
            throw error
        }

        updated.status = .paid
        updated.paidDate = Date()
        updated.paidAmount = questGoldToPayout

        cacheService?.upsertAllowancePeriod(updated)
        let isOwner = appState.isZoneOwner
        syncCoordinator?.enqueueSave(recordID: updated.id, isOwner: isOwner)

        if resolvedProfile?.payoutPolicy != .realTime {
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

        guard profile.payoutPolicy == .realTime else { return nil }
        let weekOf = WeekMath.startOfWeek(for: date, payoutDay: profile.payoutDay ?? family.payoutDay)
        let periodRecordName = "period-\(family.id.recordName)-\(profile.id.recordName)-\(Int(weekOf.timeIntervalSince1970))"
        let alreadyInFlight = inFlightSettlements.withLock { $0.contains(periodRecordName) }
        if alreadyInFlight {
            return nil
        }
        inFlightSettlements.withLock { _ = $0.insert(periodRecordName) }
        defer { inFlightSettlements.withLock { _ = $0.remove(periodRecordName) } }

        let period = try await getOrCreateAllowancePeriod(profile: profile, weekOf: weekOf, family: family)

        let breakdown = try await weeklyBreakdown(profile: profile, family: family, weekOf: weekOf)

        // Compute quest earnings fresh from QuestCompletions since real-time
        // settlement occurs before the ledger entry is minted.
        let logs = try await fetchQuestLogs(profile: profile,
                                            weekStarting: weekOf,
                                            weekEnding: TreasuryService.weekRange(starting: weekOf).upperBound)
        let questGold = try await sumGold(for: logs, family: family)

        var updated = period
        updated.paidAmount = questGold
        updated.paidDate = Date()
        if period.paidAmount != updated.paidAmount {
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
        return period
    }

    /// Mints or skips a quest-earnings LedgerEntry for a batch/manual payout.
    /// Idempotent: uses "payout-<periodRecordName>" as the entry's record name.
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
        if let cache = cacheService {
            let cachedEntries = cache.fetchLedgerEntries(profileRecordName: profile.recordID.recordName, family: family.recordID.recordName)
            if cachedEntries.first(where: { $0.recordName == entryRecordName }) != nil {
                return
            }
            // Defense-in-depth: if the hero's payout policy was unresolvable
            // at payout time but real-time settlement already recorded this
            // period's earnings as an "rt-" entry, do not mint a second — it
            // would double-count the week's quest earnings in currentBalance.
            if cachedEntries.first(where: { $0.recordName == "rt-\(periodRecordName)" }) != nil {
                return
            }

            // Verify period state before minting ledger entry
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

    /// Upserts a real-time quest-earnings LedgerEntry. The record name is derived
    /// from the AllowancePeriod so incremental settlements update the same row.
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

    /// Cache-first read. Background refresh handled by CKSyncEngine via push notifications.
    private func fetchAllLedgerEntries(profile: Profile) async throws -> [LedgerEntry] {
        let familyName = profile.family.recordID.recordName
        if let cache = cacheService {
            let cached = cache.fetchLedgerEntries(
                profileRecordName: profile.id.recordName,
                family: familyName
            )
            if cache.isCacheFresh(familyRecordName: familyName, type: .ledgerEntry) {
                return cached.map { $0.toLedgerEntry(zoneID: profile.id.zoneID) }
            }
        }
        // Fallback to CloudKit
        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(format: "profile == %@",
                                    profileRef as CVarArg)
        let entries = try await cloudKit.query(LedgerEntry.self, predicate: predicate, in: profile.id.zoneID)
        cacheService?.upsertLedgerEntries(entries)
        return entries
    }

    /// Cache-first read. Background refresh handled by CKSyncEngine via push notifications.
    func fetchAllowancePeriods(family: Family) async -> [AllowancePeriod] {
        let familyName = family.id.recordName
        if let cache = cacheService {
            let cached = cache.fetchAllowancePeriods(family: familyName)
            if cache.isCacheFresh(familyRecordName: familyName, type: .allowancePeriod) {
                return cached.map { $0.toAllowancePeriod(zoneID: family.id.zoneID) }
            }
        }

        // Fallback to CloudKit — preserve the original sort: newest week first.
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let predicate = NSPredicate(format: "family == %@", familyRef)
        let all: [AllowancePeriod]
        do {
            all = try await cloudKit.query(
                AllowancePeriod.self,
                predicate: predicate,
                in: family.id.zoneID,
                sortDescriptors: [NSSortDescriptor(key: "weekOf", ascending: false)]
            )
        } catch {
            logger.warning("Failed to fetch allowance periods: \(error, privacy: .private)")
            all = []
        }
        cacheService?.upsertAllowancePeriods(all)
        return all
    }

    /// Cache-first read. Background refresh handled by CKSyncEngine via push notifications.
    private func fetchLedgerEntries(profile: Profile, in dateRange: Range<Date>) async throws -> [LedgerEntry] {
        let profileName = profile.id.recordName
        let familyName = profile.family.recordID.recordName
        if let cache = cacheService {
            let cached = cache.fetchLedgerEntries(profileRecordName: profileName, family: familyName)
            let filtered = cached.filter { dateRange.contains($0.date) }
            if cache.isCacheFresh(familyRecordName: familyName, type: .ledgerEntry) {
                return filtered.map { $0.toLedgerEntry(zoneID: profile.id.zoneID) }
            }
        }

        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(
            format: "profile == %@ AND date >= %@ AND date < %@",
            profileRef as CVarArg,
            dateRange.lowerBound as CVarArg,
            dateRange.upperBound as CVarArg
        )
        let entries = try await cloudKit.query(LedgerEntry.self, predicate: predicate, in: profile.id.zoneID)
        cacheService?.upsertLedgerEntries(entries)
        return entries
    }

    /// Cache-first read. Background refresh handled by CKSyncEngine via push notifications.
    private func fetchQuestLogs(profile: Profile,
                                weekStarting: Date,
                                weekEnding: Date) async throws -> [QuestCompletion]
    {
        if let cache = cacheService {
            let profileName = profile.id.recordName
            let familyName = profile.family.recordID.recordName
            let cached = cache.fetchQuestCompletions(family: familyName)
                .filter { $0.completerRecordName == profileName && $0.weekOf >= weekStarting && $0.weekOf < weekEnding }
            if cache.isCacheFresh(familyRecordName: familyName, type: .questCompletion) {
                return cached.map { $0.toQuestCompletion(zoneID: profile.id.zoneID) }
            }
        }

        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(format: "completedBy == %@", profileRef as CVarArg)
        let all = try await cloudKit.query(QuestCompletion.self, predicate: predicate, in: profile.id.zoneID)
        cacheService?.upsertQuestCompletions(all)
        return all.filter { $0.weekOf >= weekStarting && $0.weekOf < weekEnding }
    }

    /// Cache-first read. Background refresh handled by CKSyncEngine via push notifications.
    private func fetchAssignedQuests(profile: Profile,
                                     family: Family,
                                     weekOf: Date) async throws -> [Quest]
    {
        let payoutDay = profile.payoutDay ?? family.payoutDay
        let range = TreasuryService.weekRange(starting: WeekMath.startOfWeek(for: weekOf, payoutDay: payoutDay))
        if let cache = cacheService {
            let familyName = family.id.recordName
            let cached = cache.fetchQuests(family: familyName)
            let filtered = cached.filter {
                $0.assigneeRecordName == profile.id.recordName &&
                    $0.isActive &&
                    range.contains($0.weekOf)
            }
            if cache.isCacheFresh(familyRecordName: familyName, type: .quest) {
                return filtered.map { $0.toQuest(zoneID: family.id.zoneID) }
            }
        }

        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let predicate = NSPredicate(
            format: "family == %@ AND isActive == 1",
            familyRef as CVarArg
        )
        let all = try await cloudKit.query(Quest.self, predicate: predicate, in: family.id.zoneID)
        cacheService?.upsertQuests(all)
        return all.filter { range.contains($0.weekOf) }
    }

    /// Cache-first read. Background refresh handled by CKSyncEngine via push notifications.
    private func fetchAllowancePeriod(profile: Profile,
                                      weekOf: Date) async throws -> AllowancePeriod?
    {
        let familyName = profile.family.recordID.recordName
        if let cache = cacheService {
            let profileName = profile.id.recordName
            let cached = cache.fetchAllowancePeriods(profileRecordName: profileName, family: familyName)
                .first { Calendar.iso8601UTC.isDate($0.weekOf, inSameDayAs: weekOf) }
            if cache.isCacheFresh(familyRecordName: familyName, type: .allowancePeriod) {
                return cached?.toAllowancePeriod(zoneID: profile.id.zoneID)
            }
        }

        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(
            format: "profile == %@ AND weekOf == %@",
            profileRef as CVarArg,
            weekOf as CVarArg
        )
        let periods = try await cloudKit.query(AllowancePeriod.self,
                                               predicate: predicate,
                                               in: profile.id.zoneID)
        cacheService?.upsertAllowancePeriods(periods)
        return periods.first
    }

    /// Cache-first profile read for the settlement/payout paths. Serves the
    /// profile from the family's cached rows when available, else falls through
    /// to CloudKit.
    private func resolveProfile(recordID: CKRecord.ID, familyRecordName: String) async throws -> Profile {
        if let cache = cacheService,
           let cached = cache.fetchProfile(recordName: recordID.recordName, family: familyRecordName)
        {
            return cached.toProfile(zoneID: recordID.zoneID)
        }
        let fetched = try await cloudKit.fetch(Profile.self, id: recordID)
        guard fetched.family.recordID.recordName == familyRecordName else {
            throw FamilyServiceError.unauthorized
        }
        cacheService?.upsertProfile(fetched)
        return fetched
    }

    /// Cache-first family read for the settlement/payout paths. Serves the
    /// family's cached record when available, else falls through to CloudKit.
    private func resolveFamily(recordID: CKRecord.ID) async throws -> Family {
        if let cache = cacheService,
           let cached = cache.fetchFamily(recordName: recordID.recordName)
        {
            return cached.toFamily(zoneID: recordID.zoneID)
        }
        return try await cloudKit.fetch(Family.self, id: recordID)
    }

    private func sumGold(for logs: [QuestCompletion], family: Family? = nil) async throws -> Double {
        await GoldCalculation.totalCredit(
            logs: logs,
            cacheService: cacheService,
            cloudKit: cloudKit,
            family: family
        )
    }

    private static func isCompleted(_ log: QuestCompletion) -> Bool {
        log.verificationStatus == .verified
            || log.verificationStatus == .autoApproved
    }

    static func weekRange(starting monday: Date) -> Range<Date> {
        WeekMath.weekRange(starting: monday)
    }

    static func mondayOfWeek(for date: Date) -> Date {
        WeekMath.mondayOfWeek(for: date)
    }
}
