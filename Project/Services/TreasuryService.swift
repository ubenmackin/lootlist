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
protocol HydrationHandling: AnyObject {
    func hydrateFromQuery(models: [some CloudKitRecord], databaseScope: CKDatabase.Scope, zoneID: CKRecordZone.ID) async
}

@MainActor
extension CKSyncEngineDelegateHandler: HydrationHandling {}

@MainActor
final class NoopHydrationHandler: HydrationHandling {
    static let shared = NoopHydrationHandler()
    private static var hasLogged = false
    private static let logger = Logger(category: "SyncEnqueuing")
    func hydrateFromQuery(models _: [some CloudKitRecord], databaseScope _: CKDatabase.Scope, zoneID _: CKRecordZone.ID) async {
        // WHY: doubles carry no engine so hydration has nowhere to ingest; cache writes and enqueues still apply.
        if !Self.hasLogged {
            Self.hasLogged = true
            Self.logger.warning("Hydration no-op: no engine backing this coordinator; continuing cache-only")
        }
    }
}

@MainActor
extension CKSyncEngineCoordinator: HydrationHandling {
    func hydrateFromQuery(models: [some CloudKitRecord], databaseScope: CKDatabase.Scope, zoneID: CKRecordZone.ID) async {
        await delegateHandler.hydrateFromQuery(models: models, databaseScope: databaseScope, zoneID: zoneID)
    }
}

@MainActor
extension NoopSyncEnqueuing: HydrationHandling {
    func hydrateFromQuery(models: [some CloudKitRecord], databaseScope: CKDatabase.Scope, zoneID: CKRecordZone.ID) async {
        await NoopHydrationHandler.shared.hydrateFromQuery(models: models, databaseScope: databaseScope, zoneID: zoneID)
    }
}

@MainActor
extension SyncEnqueuing {
    var hydrationHandler: any HydrationHandling {
        (self as? any HydrationHandling) ?? NoopHydrationHandler.shared
    }
}

@MainActor
@Observable
final class TreasuryService {
    let logger = Logger(category: "TreasuryService")
    let cloudKit: any CloudKitServiceProtocol
    let notificationService: NotificationService?
    var cacheService: any CacheServicing
    let syncCoordinator: any SyncEnqueuing
    var ledgerService: LedgerService?

    var resolvedLedgerService: LedgerService {
        if let ledgerService {
            return ledgerService
        }
        return LedgerService(
            cloudKit: cloudKit,
            cacheService: cacheService,
            appState: appState,
            syncCoordinator: syncCoordinator
        )
    }

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
        cacheService: any CacheServicing,
        toastManager: ToastManager? = nil,
        appState: AppState,
        syncCoordinator: any SyncEnqueuing
    ) {
        self.cloudKit = cloudKit
        self.notificationService = notificationService
        self.cacheService = cacheService
        self.appState = appState
        self.toastManager = toastManager
        self.syncCoordinator = syncCoordinator
    }

    private static let staticLogger = Logger(category: "TreasuryService")

    @_disfavoredOverload
    convenience init(
        cloudKit: any CloudKitServiceProtocol,
        notificationService: NotificationService? = nil,
        cacheService: (any CacheServicing)? = nil,
        toastManager: ToastManager? = nil,
        appState: AppState? = nil,
        syncCoordinator: (any SyncEnqueuing)? = nil
    ) {
        let cache: any CacheServicing
        if let cacheService {
            cache = cacheService
        } else {
            Self.staticLogger.warning("TreasuryService initialized without cacheService; using fallback in-memory cache.")
            cache = CacheService.inMemoryFallback(logger: Self.staticLogger)
        }
        let state = appState ?? AppState()
        // WHY single stack: shared coordinator owns hydration; ephemeral engines fork freshness.
        if let coord: any SyncEnqueuing = syncCoordinator ?? AppDependencies.shared?.syncCoordinator {
            self.init(cloudKit: cloudKit, notificationService: notificationService, cacheService: cache, toastManager: toastManager, appState: state, syncCoordinator: coord)
        } else {
            #if DEBUG
                if TestEnvironment.isRunningUnitOrUITests {
                    // WHY test seam: unit tests inject no engine, so cache-only coordination keeps reads deterministic.
                    Self.staticLogger.warning("TreasuryService initialized without syncCoordinator; using test Noop seam.")
                } else {
                    Self.staticLogger.error("TreasuryService initialized without syncCoordinator and no shared coordinator; falling back to Noop seam.")
                }
                self.init(
                    cloudKit: cloudKit,
                    notificationService: notificationService,
                    cacheService: cache,
                    toastManager: toastManager,
                    appState: state,
                    syncCoordinator: NoopSyncEnqueuing()
                )
            #else
                // WHY fail-closed: production without engine must not drop writes.
                preconditionFailure("TreasuryService requires a sync coordinator in production")
            #endif
        }
    }

    // MARK: - Balance & Weekly Breakdown

    /// WHY derivation-only: payout verification reconciles against CloudKit; UI balances use bucketBalances/totalBalance so tiles render instantly offline.
    func currentBalance(for profile: Profile) async throws -> Int64 {
        try await resolvedLedgerService.currentBalance(for: profile)
    }

    /// WHY cache-only: tiles and rings render from SwiftData with zero CloudKit wait.
    func bucketBalances(profileRecordName: String, familyRecordName: String) -> [BucketKind: Int64] {
        let entries = cacheService.fetchLedgerEntries(profileRecordName: profileRecordName, family: familyRecordName)
        return BucketService.bucketBalances(for: entries, profileRecordName: profileRecordName)
    }

    /// WHY cache-only: labels sum cached buckets with zero CloudKit wait.
    func totalBalance(profileRecordName: String, familyRecordName: String) -> Int64 {
        BucketService.totalBalance(bucketBalances: bucketBalances(profileRecordName: profileRecordName, familyRecordName: familyRecordName))
    }

    struct WeeklyBreakdown: Equatable, Sendable {
        var questsCount: Int = 0

        var goldFromQuests: Int64 = 0

        var bonusGold: Int64 = 0

        var totalEarned: Int64 = 0

        var spent: Int64 = 0

        var net: Int64 = 0

        var payoutStatus: PayoutStatus?
        var paidAmount: Int64?
    }

    /// WHY derivation-only: payout math reconciles against CloudKit; UI tiles use cache rebuilds so balances render instantly offline.
    func weeklyBreakdown(profile: Profile,
                         family: Family,
                         weekOf: Date) async throws -> WeeklyBreakdown
    {
        let (startOfWeek, weekRange) = WeekMath.range(for: weekOf, payoutDay: profile.payoutDay ?? family.payoutDay)
        let logs = try await fetchQuestLogs(profile: profile,
                                            weekStarting: startOfWeek,
                                            weekEnding: weekRange.upperBound)
        let quests = try await fetchQuestsForGold(family: family, logs: logs)
        // WHY day count wins: stale targetCount under-counts specific-days split rewards on payout paths.
        let templatesByID = SpecificDaysHelper.templatesByID(cache: cacheService, familyName: family.id.recordName, zoneID: family.id.zoneID)
        var goldFromQuests = GoldCalculation.totalCreditPennies(for: quests, logs: logs, templatesByID: templatesByID)
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
                    let target = SpecificDaysHelper.effectiveTarget(for: quest, templatesByID: templatesByID)
                    return GoldCalculation.isFullyCompleted(quest: quest, approvedCount: questLogs.count, effectiveTarget: target)
                }.count
                if fullyCompletedCount < assigned.count {
                    goldFromQuests = 0
                }
            }
        }

        let ledgerEntries: [LedgerEntry] = try await resolvedLedgerService.fetchLedgerEntries(profile: profile, in: weekRange)
        let bonusGold = ledgerEntries
            // WHY single-count: goal markers reuse quest/deposit pennies and transfers move between buckets.
            .filter { BucketService.isBonusCounted($0) }
            .reduce(0) { $0 + $1.amount }
        let spent = ledgerEntries
            // WHY counted only: nil-bucket residue would count in spent but not ledgerBalance.
            .filter { $0.amount < 0 && BucketService.isCounted($0) }
            .reduce(0) { $0 + $1.amount }

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
        guard profile.role == .hero else {
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

            let normalizedWeekStart = WeekMath.startOfDay(for: startOfWeek)
            // WHY fail-closed: unknown scope never queries with a guessed database.
            guard let scope = DatabaseScopeResolver.resolvedScope(appState: appState) else {
                throw FamilyServiceError.unauthorized
            }
            let matched: [AllowancePeriod] = try await CacheFirst.cacheFirst(
                type: .allowancePeriod,
                family: family,
                cacheService: cacheService,
                scope: scope,
                operations: .init(
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
                    hydrate: { [syncCoordinator, scope, profile] models in
                        await syncCoordinator.hydrationHandler.hydrateFromQuery(
                            models: models,
                            databaseScope: scope,
                            zoneID: profile.id.zoneID
                        )
                    }
                )
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
                         totalEarned: Int64? = nil,
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
        var questGoldToPayout: Int64 = 0
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
            Task { [weak self, logger, notificationService, period] in
                do {
                    guard let self else { return }
                    let profile = try await self.resolveProfile(recordID: period.profile.recordID, familyRecordName: period.family.recordID.recordName)
                    let family = try await self.resolveFamily(recordID: period.family.recordID)
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
        // WHY day count wins: stale targetCount under-counts specific-days split rewards on payout paths.
        let questGold = GoldCalculation.totalCreditPennies(
            for: quests,
            logs: logs,
            templatesByID: SpecificDaysHelper.templatesByID(cache: cacheService, familyName: family.id.recordName, zoneID: family.id.zoneID)
        )
        let questsCount = logs.filter { TreasuryService.isCompleted($0) }.count

        var updated = period
        let priorPaid = period.paidAmount ?? 0
        updated.paidAmount = max(priorPaid, questGold)
        updated.paidDate = Date()
        // Single persistence point — totalEarned / questsCompleted are always
        // reconciled from the live quest snapshot regardless of whether
        // paidAmount moved, so one call covers both cases.
        let saved = try await updateAllowance(period: updated,
                                              totalEarned: questGold,
                                              questsCompleted: questsCount)

        // WHY future-only: splits credit new money at current percentages, never rebase prior attribution.
        let totalPennies = Int(questGold)
        let priorPennies = Int(priorPaid)
        let deltaPennies = totalPennies - priorPennies
        guard deltaPennies > 0 else { return saved }
        let rtIsOwner = ActiveFamilyScopeGuard.correctedIsOwner(appState: appState, logger: logger, context: "TreasuryService.processRealTimeSettlement")
        await mintRealTimeLedgerEntry(
            periodRecordName: period.id.recordName,
            amount: Int64(deltaPennies),
            weekOf: weekOf,
            profile: profile,
            family: CKRecord.Reference(recordID: family.id, action: .none),
            date: Date(),
            isOwner: rtIsOwner
        )

        return saved
    }

    // MARK: - Ledger Minting

    private func mintRealTimeLedgerEntry(
        periodRecordName: String,
        amount: Int64,
        weekOf: Date,
        profile: Profile?,
        family: CKRecord.Reference,
        date: Date,
        isOwner: Bool
    ) async {
        guard amount > 0 else { return }
        // The split snapshot lives on the hero record; without it there is
        // nothing to attribute against, so fail closed rather than guessing.
        guard let profile else {
            logger.warning("Skipping real-time bucket split for \(periodRecordName, privacy: .private): hero profile unresolved")
            return
        }
        let baseRecordName = DeterministicRecordID.realtimePayout(periodRecordName: periodRecordName)
        let payoutRecordName = DeterministicRecordID.payout(periodRecordName: periodRecordName)

        let cachedEntries = resolvedLedgerService.cachedLedgerEntries(
            profileRecordName: profile.id.recordName,
            familyRecordName: family.recordID.recordName
        )
        // WHY batch twin blocks: weekly payout already credited this week, so real-time must not double-count on policy flip.
        if cachedEntries.contains(where: { $0.recordName == payoutRecordName || $0.recordName.hasPrefix("\(payoutRecordName)-") }) {
            return
        }

        // WHY single helper: batch and real-time share one splitPennies mint plus FIFO cascade.
        await mintSplitLedgerEntries(
            SplitMintContext(
                baseRecordName: baseRecordName,
                periodRecordName: periodRecordName,
                amount: amount,
                weekOf: weekOf,
                profile: profile,
                family: family,
                date: date,
                isOwner: isOwner,
                isRealTime: true
            )
        )
    }
}
