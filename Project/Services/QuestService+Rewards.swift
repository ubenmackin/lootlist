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
        guard let appState, let acting = appState.currentProfile,
              acting.id == hero.id || acting.role.isParent
        else {
            throw FamilyServiceError.unauthorized
        }
        // Calculate approved logs count avoiding double-counting if current completion is already cached.
        let logs = try await fetchQuestLogs(forQuest: quest, useCache: true)
        let approvedLogs = logs.filter { $0.verificationStatus == .verified || $0.verificationStatus == .autoApproved }
        let priorApproved = approvedLogs.count
        let alreadyCounted = approvedLogs.contains { $0.id.recordName == completion.id.recordName }
        let approvedCount = alreadyCounted ? max(1, priorApproved) : max(1, priorApproved + 1)

        let creditedGold = GoldCalculation.creditAsDouble(for: quest, approvedCount: approvedCount)

        if completion.xpCredited == nil {
            let currentQuest = await resolveAuthoritativeQuest(quest)
            let remaining = GoldCalculation.marginalXPCredit(
                for: currentQuest,
                approvedCount: approvedCount,
                alreadyCredited: currentQuest.xpBanked
            )

            if remaining > 0 {
                let heroProfile = resolveAuthoritativeHero(hero)
                let (totalXP, _) = xpService.calculatedXP(baseXP: remaining, profile: heroProfile)

                // Deterministic idempotency key: reward-{completionID} in the quest's zone.
                // Construct the event locally but do not persist or enqueue until the
                // server confirms this device won the atomic claim.
                let rewardID = RewardEvent.recordID(completionRecordName: completion.id.recordName, zoneID: quest.id.zoneID)
                let rewardEvent = cacheService?.fetchRewardEvent(
                    recordName: rewardID.recordName,
                    family: quest.family.recordID.recordName
                )?.toRewardEvent(zoneID: quest.id.zoneID) ?? RewardEvent(
                    profile: CKRecord.Reference(recordID: hero.id, action: .none),
                    questCompletion: CKRecord.Reference(recordID: completion.id, action: .none),
                    xpAmount: totalXP,
                    goldAmount: creditedGold,
                    timestamp: completion.completedDate,
                    family: quest.family,
                    id: rewardID
                )

                // Atomic gate: only the device that creates the record on CloudKit wins.
                // Local persistence and sync enqueue must happen after this point to avoid
                // leaving a phantom RewardEvent that would later rehydrate xpCredited via
                // BackgroundCacheActor.reconcileRewardEventsWithoutSave in the batch commit path and double-credit.
                guard try await cloudKit.claimRewardEvent(rewardEvent, in: quest.id.zoneID, using: nil) else {
                    // Lost the race — another device already claimed the deterministic event.
                    // Remove any phantom local row so reconcile cannot hydrate xpCredited on the loser.
                    await cacheService?.removePhantomRewardEvent(recordName: rewardID.recordName, family: quest.family.recordID.recordName)
                    return 0
                }
                await cacheService?.upsertRewardEvent(rewardEvent)
                // WHY: owner routing uses Family.creatorUserRecordName anchor via resolvedIsOwner, not role.
                let isOwnerReward = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState)
                let storedOwnerReward = appState.isZoneOwner
                if isOwnerReward != storedOwnerReward {
                    Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "QuestService")
                        .warning("QuestService.applyReward rewardEvent isOwner corrected via creator anchor: stored=\(storedOwnerReward) resolved=\(isOwnerReward)")
                }
                syncCoordinator?.enqueueRewardEvent(rewardEvent, isOwner: isOwnerReward)

                // Grant XP only after this device atomically claimed the event.
                try await xpService.addXP(totalXP, to: hero)

                var updatedQuest = currentQuest
                updatedQuest.xpBanked = currentQuest.xpBanked + remaining
                await cacheService?.upsertQuest(updatedQuest)
                // WHY: owner routing uses Family.creatorUserRecordName anchor via resolvedIsOwner, not role.
                let isOwner = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState)
                let storedOwner = appState.isZoneOwner
                if isOwner != storedOwner {
                    Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "QuestService")
                        .warning("QuestService.applyReward quest isOwner corrected via creator anchor: stored=\(storedOwner) resolved=\(isOwner)")
                }
                syncCoordinator?.enqueueSave(recordID: updatedQuest.id, isOwner: isOwner)

                await stampCompletionCredit(completion, xpGain: remaining)

                // Loot drop rolls only when the reward actually settles (winner only).
                // Gating on successful claim prevents double-rolling across concurrent devices.
                let rarity = QuestRarity.from(xp: quest.xpReward)
                let streakDays = currentStreak(for: heroProfile, familyName: quest.family.recordID.recordName)
                await lootDropService?.rollAndCredit(questRarity: rarity, streakDays: streakDays, to: heroProfile, eventKey: completion.id.recordName)
            } else {
                // Cap reached: no marginal XP remains. Stamp 0 so the GoldCalculation cap
                // is enforced via the idempotency marker and a re-run cannot re-credit.
                await stampCompletionCredit(completion, xpGain: 0)
            }
        }

        // Resolve family for real-time settlement from cache only — tests and
        // offline paths must not trigger a live CloudKit fetch that requires
        // entitlements or network. A missing cached family falls back to the
        // hero's own payoutPolicy below.
        let questFamilyID = quest.family.recordID
        let resolvedFamily: Family? = cacheService?.fetchFamily(recordName: questFamilyID.recordName)?
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

        return creditedGold
    }

    private func resolveAuthoritativeQuest(_ quest: Quest) async -> Quest {
        let familyName = quest.family.recordID.recordName
        if let cached = cacheService?.fetchQuest(recordName: quest.id.recordName, family: familyName) {
            return cached.toQuest(zoneID: quest.id.zoneID)
        }
        return quest
    }

    private func resolveAuthoritativeHero(_ hero: Profile) -> Profile {
        let familyName = hero.family.recordID.recordName
        if let cached = cacheService?.fetchProfile(recordName: hero.id.recordName, family: familyName) {
            return cached.toProfile(zoneID: hero.id.zoneID)
        }
        return hero
    }

    private func stampCompletionCredit(_ completion: QuestCompletion, xpGain: Int) async {
        var updated = completion
        updated.xpCredited = xpGain
        await cacheService?.upsertQuestCompletion(updated)
        // WHY: owner routing uses Family.creatorUserRecordName anchor via resolvedIsOwner, not role.
        let isOwner = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState)
        let storedOwner = appState?.isZoneOwner ?? false
        if isOwner != storedOwner {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "QuestService")
                .warning("QuestService.stampCompletionCredit isOwner corrected via creator anchor: stored=\(storedOwner) resolved=\(isOwner)")
        }
        syncCoordinator?.enqueueSave(recordID: updated.id, isOwner: isOwner)
    }

    /// Cache-only quest-completion streak for `hero`, mirroring the
    /// `HeroDashboardViewModel.streak` computation so the loot-drop streak
    /// bonus matches the value the hero dashboard renders. When the
    /// quest-completion cache is not fresh (cold install or unfresh family),
    /// the local StreakCalculator would see a missing yesterday completion
    /// and yield 0 bonus when the UI shows 5+. Fall back to the
    /// CloudKit-backed `Profile.dailyLoginStreakDays` (authoritative) in
    /// that case — the same value `XPService.calculatedXP(baseXP:profile:)`
    /// uses — so the streak multiplier never diverges from the level/XP
    /// path. `streakDays` param is the authoritative source when cache is
    /// unfresh; the computed streak is used only when cache is fresh.
    private func currentStreak(for hero: Profile, familyName: String) -> Int {
        guard let cache = cacheService else { return hero.dailyLoginStreakDays }
        let heroLogs = cache.fetchQuestCompletions(family: familyName)
            .filter { $0.completerRecordName == hero.id.recordName }
        // WHY: freshness-only sole authority — stale cache must re-validate via CloudKit; explicit stale fallback handled at call site (FamilyService-style).
        if !cache.isCacheAuthoritative(familyRecordName: familyName, type: .questCompletion, cachedCount: heroLogs.count) {
            return hero.dailyLoginStreakDays
        }
        return StreakCalculator.computeStreak(from: heroLogs)
    }
}
