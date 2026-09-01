//
//  QuestService+Rewards.swift
//  LootList
//
//  Created by Ben Mackin on 8/6/26.
//

import CloudKit
import Foundation
import os

// MARK: - Reward Application & XP Banking

extension QuestService {
    @discardableResult
    func applyReward(for quest: Quest, to hero: Profile, completion: QuestCompletion) async throws -> Double {
        guard let acting = appState.currentProfile,
              acting.id == hero.id || acting.role.isParent
        else {
            throw FamilyServiceError.unauthorized
        }
        let approvedCount = try await calculateApprovedCount(for: quest, completion: completion)
        let creditedGold = GoldCalculation.creditAsDouble(for: quest, approvedCount: approvedCount)
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
        let logs = try await fetchQuestLogs(forQuest: quest, useCache: true)
        let approvedLogs = logs.filter { $0.verificationStatus == .verified || $0.verificationStatus == .autoApproved }
        let priorApproved = approvedLogs.count
        let alreadyCounted = approvedLogs.contains { $0.id.recordName == completion.id.recordName }
        return alreadyCounted ? max(1, priorApproved) : max(1, priorApproved + 1)
    }

    private func handleXPCredit(
        quest: Quest,
        hero: Profile,
        completion: QuestCompletion,
        approvedCount: Int,
        creditedGold: Double
    ) async throws -> Double? {
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
        creditedGold: Double,
        remaining: Int
    ) async throws -> Double? {
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
                // Loser: no phantom was persisted before claim, so ensure no pending enqueue remains.
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
            logger: Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "QuestService"),
            context: "QuestService.applyReward"
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
        creditedGold: Double
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
        let isOwnerReward = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState)
        let storedOwnerReward = appState.isZoneOwner
        if isOwnerReward != storedOwnerReward {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "QuestService")
                .warning("QuestService.applyReward rewardEvent isOwner corrected via creator anchor: stored=\(storedOwnerReward) resolved=\(isOwnerReward)")
        }
        syncCoordinator.enqueueRewardEvent(rewardEvent, isOwner: isOwnerReward)
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
        creditedGold: Double,
        baselines: RewardBaselines
    ) async throws -> Double? {
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
        await revertProfileXP(hero: hero, zoneID: quest.id.zoneID, baselineXP: baselineXP, context: "QuestService.applyReward.loserRollback")
        var revertedQuest = currentQuest
        revertedQuest.xpBanked = baselineBanked
        await cacheService.upsertQuest(revertedQuest)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(
            syncCoordinator,
            id: revertedQuest.id,
            appState: appState,
            logger: Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "QuestService"),
            context: "QuestService.applyReward.loserQuestRollback"
        )
        var unstamped = completion
        unstamped.xpCredited = nil
        await cacheService.upsertQuestCompletion(unstamped)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(
            syncCoordinator,
            id: unstamped.id,
            appState: appState,
            logger: Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "QuestService"),
            context: "QuestService.applyReward.loserStampRollback"
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
        await revertProfileXP(hero: hero, zoneID: quest.id.zoneID, baselineXP: baselineXP, context: "QuestService.applyReward.hardRollbackXP")
        var revertedQuest = currentQuest
        revertedQuest.xpBanked = baselineBanked
        await cacheService.upsertQuest(revertedQuest)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(
            syncCoordinator,
            id: revertedQuest.id,
            appState: appState,
            logger: Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "QuestService"),
            context: "QuestService.applyReward.hardRollbackQuest"
        )
        var unstamped = completion
        unstamped.xpCredited = nil
        await cacheService.upsertQuestCompletion(unstamped)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(
            syncCoordinator,
            id: unstamped.id,
            appState: appState,
            logger: Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "QuestService"),
            context: "QuestService.applyReward.hardRollbackStamp"
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
            logger: Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "QuestService"),
            context: context
        )
    }

    private func settleRealTimeIfNeeded(hero: Profile, creditedGold: Double, questFamilyID: CKRecord.ID) async throws {
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
                let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "QuestService")
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
            logger: Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "QuestService"),
            context: "QuestService.stampCompletionCredit"
        )
    }

    // WHY: Bespoke fallback to local profile streak without CloudKit query/hydrate — intentionally inline, not a CacheFirst flow.
    /// Computes quest completion streak from local cache without network round-trips.
    private func currentStreak(for hero: Profile, familyName: String) -> Int {
        let cache = cacheService
        let heroLogs = cache.fetchQuestCompletions(family: familyName)
            .filter { $0.completerRecordName == hero.id.recordName }
        let scope: CKDatabase.Scope = appState.activeDatabaseScope
        if !cache.isCacheAuthoritative(familyRecordName: familyName, type: .questCompletion, scope: scope) {
            return hero.dailyLoginStreakDays
        }
        return StreakCalculator.computeStreak(from: heroLogs)
    }

    // WHY: transient CloudKit errors keep optimistic reward + XP and remain queued; hard errors rollback.
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
