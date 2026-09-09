//
//  QuestRewardService.swift
//  LootList
//
//  Created by Ben Mackin on 9/8/26.
//

import CloudKit
import Foundation
import os

/// WHY atomic claim: deterministic reward minting dedupes across devices.
@MainActor
@Observable
final class QuestRewardService {
    private let logger = Logger(category: "QuestRewardService")
    let cloudKit: any CloudKitServiceProtocol
    var cacheService: CacheService
    var appState: AppState
    var syncCoordinator: any SyncEnqueuing
    let xpService: XPService
    var treasuryService: TreasuryService?
    var lootDropService: LootDropService?
    let toastManager: ToastManager?

    init(
        cloudKit: any CloudKitServiceProtocol,
        cacheService: CacheService,
        appState: AppState,
        syncCoordinator: any SyncEnqueuing,
        xpService: XPService,
        treasuryService: TreasuryService? = nil,
        lootDropService: LootDropService? = nil,
        toastManager: ToastManager? = nil
    ) {
        self.cloudKit = cloudKit
        self.cacheService = cacheService
        self.appState = appState
        self.syncCoordinator = syncCoordinator
        self.xpService = xpService
        self.treasuryService = treasuryService
        self.lootDropService = lootDropService
        self.toastManager = toastManager
    }

    private static let staticLogger = Logger(category: "QuestRewardService")

    @_disfavoredOverload
    convenience init(
        cloudKit: any CloudKitServiceProtocol,
        cacheService: CacheService? = nil,
        appState: AppState? = nil,
        syncCoordinator: (any SyncEnqueuing)? = nil,
        xpService: XPService? = nil,
        treasuryService: TreasuryService? = nil,
        lootDropService: LootDropService? = nil,
        toastManager: ToastManager? = nil
    ) {
        let cache: CacheService
        if let cacheService {
            cache = cacheService
        } else {
            Self.staticLogger.warning("QuestRewardService initialized without cacheService; using fallback in-memory cache.")
            cache = CacheService.inMemoryFallback(logger: Self.staticLogger)
        }
        let state = appState ?? AppState()
        // WHY single shared engine: ephemeral delegate+coordinator diverge from ingest.
        let sharedCoord: (any SyncEnqueuing)? = AppDependencies.shared?.syncCoordinator
        if let coord: any SyncEnqueuing = syncCoordinator ?? sharedCoord {
            let xp = xpService ?? XPService(cloudKit: cloudKit)
            self.init(
                cloudKit: cloudKit,
                cacheService: cache,
                appState: state,
                syncCoordinator: coord,
                xpService: xp,
                treasuryService: treasuryService,
                lootDropService: lootDropService,
                toastManager: toastManager
            )
        } else {
            #if DEBUG
                if TestEnvironment.isRunningUnitOrUITests {
                    // WHY test seam: unit tests inject no engine, so cache-only coordination keeps reads deterministic.
                    Self.staticLogger.warning("QuestRewardService initialized without syncCoordinator; using test Noop seam.")
                } else {
                    Self.staticLogger.error("QuestRewardService initialized without syncCoordinator and no shared coordinator; falling back to Noop seam.")
                }
                let xp = xpService ?? XPService(cloudKit: cloudKit)
                self.init(
                    cloudKit: cloudKit,
                    cacheService: cache,
                    appState: state,
                    syncCoordinator: NoopSyncEnqueuing(),
                    xpService: xp,
                    treasuryService: treasuryService,
                    lootDropService: lootDropService,
                    toastManager: toastManager
                )
            #else
                // WHY fail-closed: production without engine must not drop writes.
                preconditionFailure("QuestRewardService requires a sync coordinator in production")
            #endif
        }
    }

    // MARK: - Reward Application & XP Banking

    @discardableResult
    func applyReward(for quest: Quest, to hero: Profile, completion: QuestCompletion) async throws -> Int64 {
        guard let acting = appState.currentProfile,
              acting.id == hero.id || acting.role.isParent
        else {
            throw FamilyServiceError.unauthorized
        }
        let approvedCount = try await calculateApprovedCount(for: quest, completion: completion)
        // WHY day count wins: legacy rows keep stale targetCount after template gains days.
        let templatesByID = SpecificDaysHelper.templatesByID(cache: cacheService, familyName: quest.family.recordID.recordName, zoneID: quest.id.zoneID)
        let effectiveTarget = SpecificDaysHelper.effectiveTarget(for: quest, templatesByID: templatesByID)
        let creditedGold = GoldCalculation.creditPennies(for: quest, approvedCount: approvedCount, effectiveTarget: effectiveTarget)
        if completion.xpCredited == nil {
            let handled = try await handleXPCredit(
                quest: quest,
                hero: hero,
                completion: completion,
                approvedCount: approvedCount,
                creditedGold: creditedGold
            )
            if let earlyReturn = handled {
                return earlyReturn
            }
        }
        try await settleRealTimeIfNeeded(hero: hero, creditedGold: creditedGold, questFamilyID: quest.family.recordID)
        return creditedGold
    }

    private func calculateApprovedCount(for quest: Quest, completion: QuestCompletion) async throws -> Int {
        let logs = try await fetchLogsForReward(forQuest: quest)
        let approvedLogs = logs.filter { $0.verificationStatus == .verified || $0.verificationStatus == .autoApproved }
        let priorApproved = approvedLogs.count
        let alreadyCounted = approvedLogs.contains { $0.id.recordName == completion.id.recordName }
        return alreadyCounted ? max(1, priorApproved) : max(1, priorApproved + 1)
    }

    /// WHY cache-first: reward path stays self-contained without a service cycle.
    private func fetchLogsForReward(forQuest quest: Quest) async throws -> [QuestCompletion] {
        let family = Family(
            name: "",
            creatorUserRecordName: nil,
            id: CKRecord.ID(recordName: quest.family.recordID.recordName, zoneID: quest.id.zoneID)
        )
        // WHY fail-closed: unknown scope serves cache only without guessing a database.
        guard let scope = DatabaseScopeResolver.resolvedScope(appState: appState) else {
            return cacheService.fetchQuestCompletions(family: family.id.recordName)
                .filter { $0.questRecordName == quest.id.recordName }
                .map { [quest] cache in cache.toQuestCompletion(zoneID: quest.id.zoneID) }
                .sorted { $0.completedDate > $1.completedDate }
        }
        return try await CacheFirst.cacheFirst(
            type: .questCompletion,
            family: family,
            cacheService: cacheService,
            scope: scope,
            operations: .init(
                fetchCache: { [cacheService, quest] familyName in
                    cacheService.fetchQuestCompletions(family: familyName)
                        .filter { $0.questRecordName == quest.id.recordName }
                },
                map: { [quest] cache in
                    cache.toQuestCompletion(zoneID: quest.id.zoneID)
                },
                query: { [cloudKit, quest] in
                    let questRef = CKRecord.Reference(recordID: quest.id, action: .none)
                    let predicate = NSPredicate(format: "quest == %@", questRef)
                    return try await cloudKit.query(
                        QuestCompletion.self,
                        predicate: predicate,
                        in: quest.id.zoneID,
                        sortDescriptors: [NSSortDescriptor(key: "completedDate", ascending: false)]
                    )
                },
                hydrate: { [syncCoordinator, scope, quest] models in
                    await syncCoordinator.hydrationHandler.hydrateFromQuery(
                        models: models,
                        databaseScope: scope,
                        zoneID: quest.id.zoneID
                    )
                },
                sortedBy: { $0.completedDate > $1.completedDate }
            )
        )
    }

    private func handleXPCredit(
        quest: Quest,
        hero: Profile,
        completion: QuestCompletion,
        approvedCount: Int,
        creditedGold: Int64
    ) async throws -> Int64? {
        let currentQuest = await resolveAuthoritativeQuest(quest)
        let remaining = GoldCalculation.marginalXPCredit(
            for: currentQuest,
            approvedCount: approvedCount,
            alreadyCredited: currentQuest.xpBanked
        )
        if remaining > 0 {
            return try await creditRewardAndClaim(
                quest: quest,
                hero: hero,
                completion: completion,
                currentQuest: currentQuest,
                approvedCount: approvedCount,
                creditedGold: creditedGold,
                remaining: remaining
            )
        }
        await stampCompletionCredit(completion, xpGain: 0)
        return nil
    }

    private func creditRewardAndClaim(
        quest: Quest,
        hero: Profile,
        completion: QuestCompletion,
        currentQuest: Quest,
        approvedCount _: Int,
        creditedGold: Int64,
        remaining: Int
    ) async throws -> Int64? {
        let heroProfile = resolveAuthoritativeHero(hero)
        let (totalXP, _) = xpService.calculatedXP(baseXP: remaining, profile: heroProfile)
        let rewardID = RewardEvent.recordID(completionRecordName: completion.id.recordName, zoneID: quest.id.zoneID)
        let rewardEvent = preparedRewardEvent(
            quest: quest,
            hero: hero,
            completion: completion,
            rewardID: rewardID,
            totalXP: totalXP,
            creditedGold: creditedGold
        )
        let baselineXP = cacheService.fetchProfile(recordName: hero.id.recordName, family: quest.family.recordID.recordName)?.xpTotal ?? hero.xp
        let baselineBanked = currentQuest.xpBanked
        // Atomic gate: claim must succeed before any local XP, quest bank, or stamp mutations.
        do {
            let claimed = try await cloudKit.claimRewardEvent(rewardEvent, in: quest.id.zoneID, using: nil)
            if !claimed {
                // WHY loser drops phantom: no pending enqueue survives lost claim race.
                await cacheService.removePhantomRewardEvent(recordName: rewardID.recordName, family: quest.family.recordID.recordName)
                syncCoordinator.dequeueSave(recordID: rewardID)
                syncCoordinator.dequeueSave(recordID: currentQuest.id)
                syncCoordinator.dequeueSave(recordID: completion.id)
                syncCoordinator.dequeueSave(recordID: hero.id)
                return 0
            }
        } catch {
            if isTransientRewardError(error) {
                // Queue the phantom for later sync but defer XP/quest/stamp until claim succeeds.
                await cacheService.upsertRewardEvent(rewardEvent)
                enqueueRewardEvent(rewardEvent)
                toastManager?.show(message: "Reward queued — will sync when online.", type: .info)
                throw error
            }
            await cacheService.removePhantomRewardEvent(recordName: rewardID.recordName, family: quest.family.recordID.recordName)
            syncCoordinator.dequeueSave(recordID: rewardID)
            throw error
        }
        // Successful claim: now persist reward and credit XP atomically.
        await cacheService.upsertRewardEvent(rewardEvent)
        enqueueRewardEvent(rewardEvent)
        do {
            try await xpService.addXP(totalXP, to: hero)
        } catch {
            if !isTransientRewardError(error) {
                await cacheService.removePhantomRewardEvent(recordName: rewardID.recordName, family: quest.family.recordID.recordName)
                syncCoordinator.dequeueSave(recordID: rewardID)
                await handleHardRollback(
                    rewardEvent: rewardEvent,
                    quest: quest,
                    hero: hero,
                    completion: completion,
                    currentQuest: currentQuest,
                    baselineXP: baselineXP,
                    baselineBanked: baselineBanked
                )
                throw error
            }
        }
        var updatedQuest = currentQuest
        updatedQuest.xpBanked = baselineBanked + remaining
        await cacheService.upsertQuest(updatedQuest)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(
            syncCoordinator,
            id: updatedQuest.id,
            appState: appState,
            logger: Logger(category: "QuestRewardService"),
            context: "QuestRewardService.applyReward"
        )
        await stampCompletionCredit(completion, xpGain: remaining)
        let rarity = QuestRarity.from(xp: quest.xpReward)
        let streakDays = currentStreak(for: heroProfile, familyName: quest.family.recordID.recordName)
        await lootDropService?.rollAndCredit(questRarity: rarity, streakDays: streakDays, to: heroProfile, eventKey: completion.id.recordName)
        return nil
    }

    private func preparedRewardEvent(
        quest: Quest,
        hero: Profile,
        completion: QuestCompletion,
        rewardID: CKRecord.ID,
        totalXP: Int,
        creditedGold: Int64
    ) -> RewardEvent {
        if let cached = cacheService.fetchRewardEvent(recordName: rewardID.recordName, family: quest.family.recordID.recordName)?
            .toRewardEvent(zoneID: quest.id.zoneID)
        {
            return cached
        }
        return RewardEvent(
            profile: CKRecord.Reference(recordID: hero.id, action: .none),
            questCompletion: CKRecord.Reference(recordID: completion.id, action: .none),
            xpAmount: totalXP,
            goldAmount: creditedGold,
            timestamp: completion.completedDate,
            family: quest.family,
            id: rewardID
        )
    }

    private func enqueueRewardEvent(_ rewardEvent: RewardEvent) {
        // WHY fail-closed: unknown scope never enqueues on a guessed database.
        guard DatabaseScopeResolver.resolvedScope(appState: appState) != nil else {
            logger.warning("QuestRewardService.applyReward dropped enqueue: unresolved scope")
            return
        }
        let isOwnerReward = ActiveFamilyScopeGuard.correctedIsOwner(appState: appState, logger: logger, context: "QuestRewardService.applyReward")
        syncCoordinator.enqueueSave(recordID: rewardEvent.id, isOwner: isOwnerReward)
    }

    private struct RewardBaselines {
        let xp: Int
        let banked: Int
    }

    private func claimRewardEvent(
        rewardEvent: RewardEvent,
        quest: Quest,
        hero: Profile,
        heroProfile: Profile,
        completion: QuestCompletion,
        currentQuest: Quest,
        creditedGold: Int64,
        baselines: RewardBaselines
    ) async throws -> Int64? {
        do {
            let claimed = try await cloudKit.claimRewardEvent(rewardEvent, in: quest.id.zoneID, using: nil)
            if !claimed {
                await handleLoserRace(
                    rewardEvent: rewardEvent,
                    quest: quest,
                    hero: hero,
                    completion: completion,
                    currentQuest: currentQuest,
                    baselineXP: baselines.xp,
                    baselineBanked: baselines.banked
                )
                return 0
            }
        } catch {
            if isTransientRewardError(error) {
                toastManager?.show(message: "Reward queued — will sync when online.", type: .info)
                return creditedGold
            }
            await handleHardRollback(
                rewardEvent: rewardEvent,
                quest: quest,
                hero: hero,
                completion: completion,
                currentQuest: currentQuest,
                baselineXP: baselines.xp,
                baselineBanked: baselines.banked
            )
            throw error
        }
        let rarity = QuestRarity.from(xp: quest.xpReward)
        let streakDays = currentStreak(for: heroProfile, familyName: quest.family.recordID.recordName)
        await lootDropService?.rollAndCredit(questRarity: rarity, streakDays: streakDays, to: heroProfile, eventKey: completion.id.recordName)
        return nil
    }

    private func handleLoserRace(
        rewardEvent: RewardEvent,
        quest: Quest,
        hero: Profile,
        completion: QuestCompletion,
        currentQuest: Quest,
        baselineXP: Int,
        baselineBanked: Int
    ) async {
        await cacheService.removePhantomRewardEvent(recordName: rewardEvent.id.recordName, family: quest.family.recordID.recordName)
        syncCoordinator.dequeueSave(recordID: rewardEvent.id)
        await revertProfileXP(hero: hero, zoneID: quest.id.zoneID, baselineXP: baselineXP, context: "QuestRewardService.applyReward.loserRollback")
        var revertedQuest = currentQuest
        revertedQuest.xpBanked = baselineBanked
        await cacheService.upsertQuest(revertedQuest)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(
            syncCoordinator,
            id: revertedQuest.id,
            appState: appState,
            logger: Logger(category: "QuestRewardService"),
            context: "QuestRewardService.applyReward.loserQuestRollback"
        )
        var unstamped = completion
        unstamped.xpCredited = nil
        await cacheService.upsertQuestCompletion(unstamped)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(
            syncCoordinator,
            id: unstamped.id,
            appState: appState,
            logger: Logger(category: "QuestRewardService"),
            context: "QuestRewardService.applyReward.loserStampRollback"
        )
    }

    private func handleHardRollback(
        rewardEvent: RewardEvent,
        quest: Quest,
        hero: Profile,
        completion: QuestCompletion,
        currentQuest: Quest,
        baselineXP: Int,
        baselineBanked: Int
    ) async {
        await cacheService.removePhantomRewardEvent(recordName: rewardEvent.id.recordName, family: quest.family.recordID.recordName)
        syncCoordinator.dequeueSave(recordID: rewardEvent.id)
        await revertProfileXP(hero: hero, zoneID: quest.id.zoneID, baselineXP: baselineXP, context: "QuestRewardService.applyReward.hardRollbackXP")
        var revertedQuest = currentQuest
        revertedQuest.xpBanked = baselineBanked
        await cacheService.upsertQuest(revertedQuest)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(
            syncCoordinator,
            id: revertedQuest.id,
            appState: appState,
            logger: Logger(category: "QuestRewardService"),
            context: "QuestRewardService.applyReward.hardRollbackQuest"
        )
        var unstamped = completion
        unstamped.xpCredited = nil
        await cacheService.upsertQuestCompletion(unstamped)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(
            syncCoordinator,
            id: unstamped.id,
            appState: appState,
            logger: Logger(category: "QuestRewardService"),
            context: "QuestRewardService.applyReward.hardRollbackStamp"
        )
    }

    private func revertProfileXP(hero: Profile, zoneID: CKRecordZone.ID, baselineXP: Int, context: String) async {
        guard let cached = cacheService.fetchProfile(recordName: hero.id.recordName, family: hero.family.recordID.recordName) else { return }
        var reverted = cached.toProfile(zoneID: zoneID)
        reverted.xp = baselineXP
        reverted.level = XPService.level(forXP: baselineXP)
        await cacheService.upsertProfile(reverted)
        if appState.currentProfile?.id.recordName == reverted.id.recordName {
            appState.currentProfile = reverted
        }
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(
            syncCoordinator,
            id: reverted.id,
            appState: appState,
            logger: Logger(category: "QuestRewardService"),
            context: context
        )
    }

    private func settleRealTimeIfNeeded(hero: Profile, creditedGold: Int64, questFamilyID: CKRecord.ID) async throws {
        let resolvedFamily: Family? = cacheService.fetchFamily(recordName: questFamilyID.recordName)?
            .toFamily(zoneID: questFamilyID.zoneID)
        let effectivePolicy = treasuryService?.effectivePayoutPolicy(for: hero, family: resolvedFamily)
            ?? hero.payoutPolicy
            ?? resolvedFamily?.payoutPolicy
            ?? .perQuest
        if effectivePolicy == .realTime, creditedGold > 0, let treasuryService, let resolvedFamily {
            do {
                _ = try await treasuryService.processRealTimeSettlement(profile: hero, family: resolvedFamily)
            } catch {
                let logger = Logger(category: "QuestRewardService")
                logger.error("Failed to process real-time settlement for hero \(hero.id.recordName, privacy: .private): \(error, privacy: .private)")
                if let toast = treasuryService.toastManager ?? self.toastManager {
                    toast.show(message: "Could not settle quest reward. Pull to retry.", type: .warning)
                } else {
                    self.toastManager?.show(message: "Could not settle quest reward. Pull to retry.", type: .warning)
                }
            }
        }
    }

    private func resolveAuthoritativeQuest(_ quest: Quest) async -> Quest {
        let familyName = quest.family.recordID.recordName
        if let cached = cacheService.fetchQuest(recordName: quest.id.recordName, family: familyName) {
            return cached.toQuest(zoneID: quest.id.zoneID)
        }
        return quest
    }

    private func resolveAuthoritativeHero(_ hero: Profile) -> Profile {
        let familyName = hero.family.recordID.recordName
        if let cached = cacheService.fetchProfile(recordName: hero.id.recordName, family: familyName) {
            return cached.toProfile(zoneID: hero.id.zoneID)
        }
        return hero
    }

    private func stampCompletionCredit(_ completion: QuestCompletion, xpGain: Int) async {
        var updated = completion
        updated.xpCredited = xpGain
        await cacheService.upsertQuestCompletion(updated)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(
            syncCoordinator,
            id: updated.id,
            appState: appState,
            logger: Logger(category: "QuestRewardService"),
            context: "QuestRewardService.stampCompletionCredit"
        )
    }

    /// WHY local streak: stats stay cache-first so offline evaluation still resolves.
    /// Computes quest completion streak from local cache without network round-trips.
    private func currentStreak(for hero: Profile, familyName: String) -> Int {
        let cache = cacheService
        let heroLogs = cache.fetchQuestCompletions(family: familyName)
            .filter { $0.completerRecordName == hero.id.recordName }
        // WHY fail-closed: unknown scope falls back without guessing a database.
        guard let scope = DatabaseScopeResolver.resolvedScope(appState: appState) else {
            return hero.dailyLoginStreakDays
        }
        if !cache.isCacheAuthoritative(familyRecordName: familyName, type: .questCompletion, scope: scope) {
            return hero.dailyLoginStreakDays
        }
        return StreakCalculator.computeStreak(from: heroLogs)
    }

    /// WHY optimistic queue: transient errors keep reward queued, hard errors roll back.
    private func isTransientRewardError(_ error: Error) -> Bool {
        if let ckError = error as? CKError {
            switch ckError.code {
            case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy, .resultsTruncated:
                return true
            case .operationCancelled:
                if let underlying = ckError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSURLErrorDomain, underlying.code == NSURLErrorTimedOut {
                    return true
                }
                return false
            default:
                if let underlying = ckError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSURLErrorDomain, underlying.code == NSURLErrorTimedOut {
                    return true
                }
                let nsErr = error as NSError
                if nsErr.domain == NSURLErrorDomain, nsErr.code == NSURLErrorTimedOut {
                    return true
                }
                return false
            }
        }
        let nsErr = error as NSError
        if nsErr.domain == NSURLErrorDomain, nsErr.code == NSURLErrorTimedOut {
            return true
        }
        if let serviceError = error as? CloudKitServiceError {
            switch serviceError {
            case .networkUnavailable, .retryable, .exhaustedBudget: return true
            default: return false
            }
        }
        return false
    }
}
