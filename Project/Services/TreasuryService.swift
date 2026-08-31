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
    var cacheService: CacheService
    let syncCoordinator: CKSyncEngineCoordinator

    /// Guards against concurrent settlement of the same period.
    private let inFlightSettlements = Mutex<Set<String>>([])

    // MARK: - Period Creation Serialization

    /// Serializes concurrent allowance period lookups per profile and week.
    private let periodLock = KeyedAsyncLock()

    var appState: AppState

    let toastManager: ToastManager?

    init(
        cloudKit: any CloudKitServiceProtocol,
        notificationService: NotificationService? = nil,
        cacheService: CacheService,
        toastManager: ToastManager? = nil,
        appState: AppState,
        syncCoordinator: CKSyncEngineCoordinator
    ) {
        self.cloudKit = cloudKit
        self.notificationService = notificationService
        self.cacheService = cacheService
        self.appState = appState
        self.toastManager = toastManager
        self.syncCoordinator = syncCoordinator
    }

    private static let staticLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "TreasuryService")

    @_disfavoredOverload
    convenience init(
        cloudKit: any CloudKitServiceProtocol,
        notificationService: NotificationService? = nil,
        cacheService: CacheService? = nil,
        toastManager: ToastManager? = nil,
        appState: AppState? = nil,
        syncCoordinator: CKSyncEngineCoordinator? = nil
    ) {
        let cache: CacheService
        if let cacheService {
            cache = cacheService
        } else {
            Self.staticLogger.warning("TreasuryService initialized without cacheService; using fallback in-memory cache.")
            cache = CacheService.inMemoryFallback(logger: Self.staticLogger)
        }
        let state = appState ?? AppState()
        let ck = cloudKit as? CloudKitService ?? CloudKitService()
        let delegate = CKSyncEngineDelegateHandler(
            backgroundCache: nil,
            conflictResolver: CKSyncConflictResolver(cacheService: cache, backgroundCache: nil, toastManager: toastManager, appState: state),
            cacheService: cache,
            appState: state
        )
        let coord = syncCoordinator ?? CKSyncEngineCoordinator(cloudKitService: ck, delegateHandler: delegate, appState: state)
        self.init(cloudKit: cloudKit, notificationService: notificationService, cacheService: cache, toastManager: toastManager, appState: state, syncCoordinator: coord)
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

    /// Calculates wallet-week gold breakdown for a hero with cache-first reads.
    func weeklyBreakdown(profile: Profile,
                         family: Family,
                         weekOf: Date) async throws -> WeeklyBreakdown
    {
        let (startOfWeek, weekRange) = WeekMath.range(for: weekOf, payoutDay: profile.payoutDay ?? family.payoutDay)
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

        let ledgerEntries: [LedgerEntry] = try await CacheFirst.cacheFirst(
            type: .ledgerEntry,
            family: family,
            cacheService: cacheService,
            appState: appState,
            fetchCache: { [cacheService, profile, weekRange] familyName in
                cacheService.fetchLedgerEntries(profileRecordName: profile.id.recordName, family: familyName)
                    .filter { weekRange.contains($0.date) }
            },
            map: { [profile] cache in
                cache.toLedgerEntry(zoneID: profile.id.zoneID)
            },
            query: { [cloudKit, profile, weekRange] in
                let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
                let predicate = NSPredicate(
                    format: "profile == %@ AND date >= %@ AND date < %@",
                    profileRef as CVarArg,
                    weekRange.lowerBound as CVarArg,
                    weekRange.upperBound as CVarArg
                )
                return try await cloudKit.query(LedgerEntry.self, predicate: predicate, in: profile.id.zoneID)
            },
            hydrate: { [syncCoordinator, appState, profile] models in
                await syncCoordinator.delegateHandler.hydrateFromQuery(
                    models: models,
                    databaseScope: appState.activeDatabaseScope,
                    zoneID: profile.id.zoneID
                )
            }
        )
        let bonusGold = ledgerEntries
            .filter { $0.amount > 0 && $0.sourceEnum != .quest }
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
        guard let acting = appState.currentProfile,
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
        let (startOfWeek, _) = WeekMath.range(for: weekOf, payoutDay: effectivePayoutDay)
        let periodRecordName = "period-\(family.id.recordName)-\(profile.id.recordName)-\(Int(startOfWeek.timeIntervalSince1970))"

        return try await periodLock.withLock(key: periodRecordName) {
            // Fast cache check for allowance period existence.
            if let cached = cacheService.fetchAllowancePeriod(recordName: periodRecordName, family: family.id.recordName) {
                return cached.toAllowancePeriod(zoneID: family.id.zoneID)
            }

            let normalizedWeekStart = Calendar.iso8601UTC.startOfDay(for: startOfWeek)
            let matched: [AllowancePeriod] = try await CacheFirst.cacheFirst(
                type: .allowancePeriod,
                family: family,
                cacheService: cacheService,
                appState: appState,
                fetchCache: { [cacheService, profile, normalizedWeekStart] familyName in
                    cacheService.fetchAllowancePeriods(profileRecordName: profile.id.recordName, family: familyName)
                        .filter { $0.weekOf == normalizedWeekStart }
                },
                map: { [family] cache in
                    cache.toAllowancePeriod(zoneID: family.id.zoneID)
                },
                query: { [cloudKit, profile, normalizedWeekStart] in
                    let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
                    let predicate = NSPredicate(
                        format: "profile == %@ AND weekOf == %@",
                        profileRef as CVarArg,
                        normalizedWeekStart as CVarArg
                    )
                    return try await cloudKit.query(AllowancePeriod.self, predicate: predicate, in: profile.id.zoneID)
                },
                hydrate: { [syncCoordinator, appState, profile] models in
                    await syncCoordinator.delegateHandler.hydrateFromQuery(
                        models: models,
                        databaseScope: appState.activeDatabaseScope,
                        zoneID: profile.id.zoneID
                    )
                }
            )
            if let existing = matched.first {
                return existing
            }

            return try await createPeriod(profile: profile, family: family, weekOf: startOfWeek)
        }
    }

    private func createPeriod(profile: Profile, family: Family, weekOf: Date) async throws -> AllowancePeriod {
        guard let acting = appState.currentProfile,
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
        let (startOfWeek, weekRange) = WeekMath.range(for: weekOf, payoutDay: effectivePayoutDay)
        let logs = try await fetchQuestLogs(profile: profile,
                                            weekStarting: startOfWeek,
                                            weekEnding: weekRange.upperBound)
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

        await cacheService.upsertAllowancePeriod(period)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: period.id, appState: appState, logger: logger, context: "TreasuryService.createPeriod")
        return period
    }

    func updateAllowance(period: AllowancePeriod,
                         totalEarned: Double? = nil,
                         questsCompleted: Int? = nil,
                         questsTotal: Int? = nil) async throws -> AllowancePeriod
    {
        guard let acting = appState.currentProfile,
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

        await cacheService.upsertAllowancePeriod(updated)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: updated.id, appState: appState, logger: logger, context: "TreasuryService.updateAllowance")
        return updated
    }

    // MARK: - Payout & Settlement

    func runPayout(period: AllowancePeriod) async throws {
        guard let acting = appState.currentProfile,
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
                // Closes empty allowance period so rollover advances correctly.
                updated.status = .paid
                updated.paidDate = Date()
                updated.paidAmount = 0
                updated.totalEarned = breakdown.totalEarned
                updated.questsCompleted = breakdown.questsCount
                await cacheService.upsertAllowancePeriod(updated)
                ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: updated.id, appState: appState, logger: logger, context: "TreasuryService.runPayout.zero")
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

        await cacheService.upsertAllowancePeriod(updated)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(syncCoordinator, id: updated.id, appState: appState, logger: logger, context: "TreasuryService.runPayout")

        let effectivePolicy = resolvedProfile.map { effectivePayoutPolicy(for: $0, family: resolvedFamily) } ?? resolvedFamily?.payoutPolicy ?? .perQuest
        if effectivePolicy != .realTime {
            let mintIsOwner = ActiveFamilyScopeGuard.correctedIsOwner(appState: appState, logger: logger, context: "TreasuryService.runPayout.mint")
            await mintBucketSplitPayout(
                periodRecordName: period.id.recordName,
                amount: updated.paidAmount ?? questGoldToPayout,
                weekOf: period.weekOf,
                profile: resolvedProfile,
                family: period.family,
                date: updated.paidDate ?? Date(),
                isOwner: mintIsOwner
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

    /// Processes immediate settlement for heroes with real-time payout policy.
    @discardableResult
    func processRealTimeSettlement(profile: Profile, family: Family, date: Date = Date()) async throws -> AllowancePeriod? {
        guard let acting = appState.currentProfile,
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
        let (weekOf, weekRange) = WeekMath.range(for: date, payoutDay: profile.payoutDay ?? family.payoutDay)
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
                                            weekEnding: weekRange.upperBound)
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

        let rtIsOwner = ActiveFamilyScopeGuard.correctedIsOwner(appState: appState, logger: logger, context: "TreasuryService.processRealTimeSettlement")
        await mintRealTimeLedgerEntry(
            periodRecordName: period.id.recordName,
            amount: questGold,
            weekOf: weekOf,
            profile: period.profile,
            family: CKRecord.Reference(recordID: family.id, action: .none),
            date: Date(),
            isOwner: rtIsOwner
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
            source: LedgerSource.quest.rawValue,
            family: family,
            id: CKRecord.ID(recordName: entryRecordName, zoneID: family.recordID.zoneID)
        )
        await cacheService.upsertLedgerEntry(entry)
        syncCoordinator.enqueueSave(recordID: entry.id, isOwner: isOwner)
        // WHY: Log uses CurrencyFormatter so currency render stays locale-aware and single-point.
        let formatted = CurrencyFormatter.string(amount)
        logger.info("Minted real-time earnings \(formatted, privacy: .public) for period \(periodRecordName, privacy: .private)")
    }
}
