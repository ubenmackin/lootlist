//
//  QuestService+Rewards.swift
//  LootList
//
//  Created by Ben Mackin on August 6, 2026.
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
        let logs = try await fetchQuestLogs(forQuest: quest, useCache: true)
        let approvedCount = max(1, logs.filter(\.verificationStatus.countsTowardCompletion).count)

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

                // Keep the immutable event local-first. The atomic claim is the
                // server-side gate; only its winner may apply XP or stamp the log.
                cacheService?.upsertRewardEvent(rewardEvent)
                syncCoordinator?.enqueueRewardEvent(rewardEvent, isOwner: appState.isZoneOwner)
                guard try await cloudKit.claimRewardEvent(rewardEvent, in: quest.id.zoneID, using: nil) else {
                    return 0
                }

                // Grant XP only after this device atomically claimed the event.
                try await xpService.addXP(totalXP, to: hero)

                // Advance xpBanked locally and enqueue for sync.
                var updatedQuest = currentQuest
                updatedQuest.xpBanked = currentQuest.xpBanked + remaining
                cacheService?.upsertQuest(updatedQuest)
                let isOwner = appState.isZoneOwner
                syncCoordinator?.enqueueSave(recordID: updatedQuest.id, isOwner: isOwner)

                // Stamp completion credit only after the claim and grant.
                await stampCompletionCredit(completion, xpGain: remaining)
            } else {
                await stampCompletionCredit(completion, xpGain: 0)
            }

            // Loot drop rolls only when the reward actually settles.
            // `applyReward` is reached on `.autoApproved` submission (hero
            // device) or parent `.verified` (verifying device) — never on a
            // `.pending` submission, which creates a log but skips this path.
            // Gating on `xpCredited == nil` also makes it idempotent across
            // repeated reward applications, so a re-run cannot double-roll.
            let rarity = QuestRarity.from(xp: quest.xpReward)
            let streakDays = currentStreak(for: hero, familyName: quest.family.recordID.recordName)
            await lootDropService?.rollAndCredit(questRarity: rarity, streakDays: streakDays, to: hero, eventKey: completion.id.recordName)
        }

        if hero.payoutPolicy == .realTime, creditedGold > 0, let treasuryService {
            let questFamilyID = quest.family.recordID
            let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "QuestService")
            Task { @MainActor [logger] in
                do {
                    let family: Family
                    if let cached = cacheService?.fetchFamily(recordName: questFamilyID.recordName),
                       cacheService?.isCacheFresh(familyRecordName: questFamilyID.recordName, type: .family) == true
                    {
                        family = cached.toFamily(zoneID: questFamilyID.zoneID)
                    } else {
                        family = try await cloudKit.fetch(Family.self, id: questFamilyID)
                        cacheService?.upsertFamily(family)
                    }
                    _ = try await treasuryService.processRealTimeSettlement(profile: hero, family: family)
                } catch {
                    logger.error("Failed to process real-time settlement for hero \(hero.id.recordName, privacy: .private): \(error, privacy: .public)")
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

    /// Resolves the authoritative hero profile from the local cache so the
    /// streak multiplier is read from the CloudKit-backed
    /// `Profile.dailyLoginStreakDays` field (never from a device-local
    /// UserDefaults counter — see ARCHITECTURE.md §2). Falls back to the
    /// passed profile when the cache is unavailable.
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
        cacheService?.upsertQuestCompletion(updated)
        let isOwner = appState?.isZoneOwner ?? false
        syncCoordinator?.enqueueSave(recordID: updated.id, isOwner: isOwner)
    }

    /// Cache-only quest-completion streak for `hero`, mirroring the
    /// `HeroDashboardViewModel.streak` computation so the loot-drop streak
    /// bonus matches the value the hero dashboard renders.
    private func currentStreak(for hero: Profile, familyName: String) -> Int {
        guard let cache = cacheService else { return 0 }
        let heroLogs = cache.fetchQuestCompletions(family: familyName)
            .filter { $0.completerRecordName == hero.id.recordName }
        return StreakCalculator.computeStreak(from: heroLogs)
    }
}
