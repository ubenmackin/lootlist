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
                let rewardID = RewardEvent.recordID(completionRecordName: completion.id.recordName, zoneID: quest.id.zoneID)
                let rewardEvent = RewardEvent(
                    profile: CKRecord.Reference(recordID: hero.id, action: .none),
                    questCompletion: CKRecord.Reference(recordID: completion.id, action: .none),
                    xpAmount: remaining,
                    goldAmount: creditedGold,
                    family: quest.family,
                    id: rewardID
                )

                // 1. Durably persist RewardEvent to CloudKit first
                _ = try await cloudKit.save(rewardEvent, in: quest.id.zoneID, using: nil)

                // 2. Grant XP to hero profile
                try await xpService.addXP(remaining, to: hero)

                // 3. Advance xpBanked locally and enqueue for sync
                var updatedQuest = currentQuest
                updatedQuest.xpBanked = currentQuest.xpBanked + remaining
                cacheService?.upsertQuest(updatedQuest)
                let isOwner = appState.isZoneOwner
                syncCoordinator?.enqueueSave(recordID: updatedQuest.id, isOwner: isOwner)

                // 4. Stamp completion credit only after confirmed save and grant
                await stampCompletionCredit(completion, xpGain: remaining)
            } else {
                await stampCompletionCredit(completion, xpGain: 0)
            }
        }

        if hero.payoutPolicy == .realTime, creditedGold > 0, let treasuryService {
            let questFamilyID = quest.family.recordID
            let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "QuestService")
            Task { [logger] in
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

    private func stampCompletionCredit(_ completion: QuestCompletion, xpGain: Int) async {
        var updated = completion
        updated.xpCredited = xpGain
        cacheService?.upsertQuestCompletion(updated)
        let isOwner = appState?.isZoneOwner ?? false
        syncCoordinator?.enqueueSave(recordID: updated.id, isOwner: isOwner)
    }
}
