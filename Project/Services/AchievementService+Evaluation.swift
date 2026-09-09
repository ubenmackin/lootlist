//
//  AchievementService+Evaluation.swift
//  LootList
//
//  Created by Ben Mackin on 9/9/26.
//

import CloudKit
import Foundation

extension AchievementService {
    func computeBestWeeklyCompletion(
        profile: Profile,
        approvedCountByQuest: [CKRecord.ID: Int],
        questCache: [CKRecord.ID: Quest],
        templatesByID: [String: QuestTemplate]
    ) -> Double {
        var bestWeekly = 0.0
        let assignedQuests = questCache.values.filter {
            $0.assignee.recordID == profile.id && $0.active
        }
        let questsByWeek = Dictionary(grouping: assignedQuests, by: \.weekOf)
        for (_, weekQuests) in questsByWeek {
            guard !weekQuests.isEmpty else { continue }
            let fullyCompletedCount = weekQuests.filter { quest in
                let approvedCount = approvedCountByQuest[quest.id] ?? 0
                // WHY day count wins: legacy rows keep stale targetCount after template gains days.
                let effectiveTarget = SpecificDaysHelper.effectiveTarget(for: quest, templatesByID: templatesByID)
                return GoldCalculation.isFullyCompleted(quest: quest, approvedCount: approvedCount, effectiveTarget: effectiveTarget)
            }.count
            let ratio = Double(fullyCompletedCount) / Double(weekQuests.count)
            bestWeekly = max(bestWeekly, min(ratio, 1.0))
        }
        return bestWeekly
    }

    func longestConsecutiveStreak(in days: Set<Int>) -> Int {
        guard !days.isEmpty else { return 0 }

        let sorted = days.sorted()
        var best = 1
        var run = 1
        for index in 1 ..< sorted.count {
            // Buckets are epoch-day integers, so a gap of exactly 1 is consecutive days.
            if sorted[index] - sorted[index - 1] == 1 {
                run += 1
                if run > best {
                    best = run
                }
            } else {
                run = 1
            }
        }
        return best
    }

    func isRequirementMet(definition: Achievement, stats: ProfileStats) -> Bool {
        switch definition.requirementType {
        case AchievementRequirement.firstQuest:
            stats.questCount >= 1

        case AchievementRequirement.questCount10:
            stats.questCount >= 10

        case AchievementRequirement.questCount25:
            stats.questCount >= 25

        case AchievementRequirement.questCount50:
            stats.questCount >= 50

        case AchievementRequirement.questCount100:
            stats.questCount >= 100

        case AchievementRequirement.weekly100:
            stats.bestWeeklyCompletion >= 1.0

        case AchievementRequirement.streak7:
            stats.longestStreakDays >= 7

        case AchievementRequirement.streak30:
            stats.longestStreakDays >= 30

        case AchievementRequirement.firstGoalCreated:
            stats.goalsCreated >= 1

        case AchievementRequirement.goalGetter:
            stats.goalsCompleted >= 1

        case AchievementRequirement.ledgerCount10:
            stats.ledgerCount >= 10

        case AchievementRequirement.earlyBird9am:
            stats.earlyBirdQualified

        // Legacy evaluation — keeps previously earned gold/ledger trophies decoding correctly.
        case AchievementRequirement.gold100:
            stats.totalGoldEarned >= 100

        case AchievementRequirement.gold500:
            stats.totalGoldEarned >= 500

        case AchievementRequirement.ledgerWeeks4:
            stats.ledgerWeeksCount >= 4
        }
    }
}
