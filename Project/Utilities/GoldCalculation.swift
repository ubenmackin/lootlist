//
//  GoldCalculation.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation
import os

/// Calculates quest reward proration for gold and XP using `Decimal` arithmetic.
enum GoldCalculation: Sendable {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "LootList",
        category: "GoldCalculation"
    )

    /// Computes prorated gold credit based on approved completion count and payout policy.
    static func credit(goldReward: Double,
                       targetCount: Int,
                       isAllOrNothing: Bool,
                       approvedCount: Int) -> Decimal
    {
        let safeTarget = max(1, targetCount)
        let capped = min(max(0, approvedCount), safeTarget)

        if isAllOrNothing {
            return capped >= safeTarget ? Decimal(goldReward) : 0
        }

        let perUnit = Decimal(goldReward) / Decimal(safeTarget)
        return perUnit * Decimal(capped)
    }

    /// Convenience for the CloudKit `Quest` model.
    static func credit(for quest: Quest, approvedCount: Int) -> Decimal {
        credit(goldReward: quest.goldReward,
               targetCount: quest.targetCount,
               isAllOrNothing: quest.isAllOrNothing,
               approvedCount: approvedCount)
    }

    /// Convenience for the SwiftData `QuestCache` model.
    static func credit(for quest: QuestCache, approvedCount: Int) -> Decimal {
        credit(goldReward: quest.goldReward,
               targetCount: quest.targetCount,
               isAllOrNothing: quest.isAllOrNothing,
               approvedCount: approvedCount)
    }

    /// Double-returning variant using banker's rounding for wallet totals.
    static func creditAsDouble(goldReward: Double,
                               targetCount: Int,
                               isAllOrNothing: Bool,
                               approvedCount: Int) -> Double
    {
        let result = credit(goldReward: goldReward,
                            targetCount: targetCount,
                            isAllOrNothing: isAllOrNothing,
                            approvedCount: approvedCount)
        return NSDecimalNumber(decimal: result).doubleValue
    }

    /// `Double`-returning convenience for the CloudKit `Quest` model.
    static func creditAsDouble(for quest: Quest, approvedCount: Int) -> Double {
        creditAsDouble(goldReward: quest.goldReward,
                       targetCount: quest.targetCount,
                       isAllOrNothing: quest.isAllOrNothing,
                       approvedCount: approvedCount)
    }

    /// `Double`-returning convenience for the SwiftData `QuestCache` model.
    static func creditAsDouble(for quest: QuestCache, approvedCount: Int) -> Double {
        creditAsDouble(goldReward: quest.goldReward,
                       targetCount: quest.targetCount,
                       isAllOrNothing: quest.isAllOrNothing,
                       approvedCount: approvedCount)
    }

    /// Cumulative XP credit for a quest, prorated and capped at xpReward.
    static func xpCredit(xpReward: Int,
                         targetCount: Int,
                         isAllOrNothing: Bool,
                         approvedCount: Int) -> Int
    {
        let safeTarget = max(1, targetCount)
        let capped = min(max(0, approvedCount), safeTarget)

        if isAllOrNothing {
            return capped >= safeTarget ? max(0, xpReward) : 0
        }

        let perUnit = Decimal(max(0, xpReward)) / Decimal(safeTarget)
        let total = perUnit * Decimal(capped)
        return Int(NSDecimalNumber(decimal: total).doubleValue)
    }

    /// Convenience for the CloudKit `Quest` model.
    static func xpCredit(for quest: Quest, approvedCount: Int) -> Int {
        xpCredit(xpReward: quest.xpReward,
                 targetCount: quest.targetCount,
                 isAllOrNothing: quest.isAllOrNothing,
                 approvedCount: approvedCount)
    }

    /// Marginal XP grant for one approved quest completion, bounded by remaining bounty.
    static func marginalXPCredit(for quest: Quest,
                                 approvedCount: Int,
                                 alreadyCredited: Int) -> Int
    {
        let cumulative = xpCredit(for: quest, approvedCount: approvedCount)
        let previous = xpCredit(for: quest, approvedCount: approvedCount - 1)
        let marginal = max(0, cumulative - previous)
        let remaining = max(0, cumulative - alreadyCredited)
        return min(marginal, remaining)
    }

    static func creditAsDecimal(xp: Int, baseRate: Double) -> Decimal {
        let rate = Decimal(baseRate)
        let xpDecimal = Decimal(xp)
        return xpDecimal * rate / Decimal(AppConstants.Economy.percentageBase)
    }

    static func creditAsDouble(xp: Int, baseRate: Double) -> Double {
        NSDecimalNumber(decimal: creditAsDecimal(xp: xp, baseRate: baseRate)).doubleValue
    }

    static func totalGold(
        for quests: [QuestCache],
        approvedLogs: [QuestCompletionCache],
        templatesByID: [String: QuestTemplateCache] = [:]
    ) -> Double {
        let questByName = Dictionary(quests.map { ($0.recordName, $0) },
                                     uniquingKeysWith: { current, _ in current })
        var countByQuest: [String: Int] = [:]
        for log in approvedLogs {
            countByQuest[log.questRecordName, default: 0] += 1
        }
        var total = 0.0
        for (qName, count) in countByQuest {
            if let quest = questByName[qName] {
                // WHY day count wins: stale targetCount under-counts specific-days split rewards.
                let target = SpecificDaysHelper.effectiveTarget(for: quest, templatesByID: templatesByID)
                total += creditAsDouble(for: quest, approvedCount: count, effectiveTarget: target)
            } else {
                logger.warning("Missing quest \(qName, privacy: .private) for gold proration")
            }
        }
        return total
    }

    /// Cached-row fully-completed check, guarded against `targetCount == 0`.
    /// Mirrors the `safeTarget = max(1, targetCount)` defense inside `credit(_:…)`
    /// so AON zero-out and per-quest completion checks can never disagree.
    static func isFullyCompleted(quest: QuestCache, approvedCount: Int) -> Bool {
        let target = max(1, quest.targetCount)
        return approvedCount >= target
    }

    /// Domain-model fully-completed check, guarded against `targetCount == 0`.
    /// Mirrors the `safeTarget = max(1, targetCount)` defense inside `credit(_:…)`
    /// so AON zero-out and per-quest completion checks can never disagree.
    static func isFullyCompleted(quest: Quest, approvedCount: Int) -> Bool {
        let target = max(1, quest.targetCount)
        return approvedCount >= target
    }

    /// Returns true if non-rejected logs already occupy all target completion slots.
    static func nonRejectedLogsReachTarget(quest: QuestCache, nonRejectedCount: Int) -> Bool {
        let target = max(1, quest.targetCount)
        return nonRejectedCount >= target
    }

    static func nonRejectedLogsReachTarget(quest: Quest, nonRejectedCount: Int) -> Bool {
        let target = max(1, quest.targetCount)
        return nonRejectedCount >= target
    }

    /// Effective slot count; day count wins so legacy rows with stale targetCount stay aligned with UI.
    static func effectiveTarget(for quest: QuestCache, specificDays: [String]) -> Int {
        SpecificDaysHelper.effectiveTarget(for: quest, specificDays: specificDays)
    }

    static func isFullyCompleted(quest _: QuestCache, approvedCount: Int, effectiveTarget: Int) -> Bool {
        let target = max(1, effectiveTarget)
        return approvedCount >= target
    }

    static func isFullyCompleted(quest: QuestCache, approvedCount: Int, specificDays: [String]) -> Bool {
        isFullyCompleted(
            quest: quest,
            approvedCount: approvedCount,
            effectiveTarget: effectiveTarget(for: quest, specificDays: specificDays)
        )
    }

    static func isFullyCompleted(quest _: Quest, approvedCount: Int, effectiveTarget: Int) -> Bool {
        let target = max(1, effectiveTarget)
        return approvedCount >= target
    }

    static func nonRejectedLogsReachTarget(quest _: QuestCache, nonRejectedCount: Int, effectiveTarget: Int) -> Bool {
        let target = max(1, effectiveTarget)
        return nonRejectedCount >= target
    }

    static func nonRejectedLogsReachTarget(quest: QuestCache, nonRejectedCount: Int, specificDays: [String]) -> Bool {
        nonRejectedLogsReachTarget(
            quest: quest,
            nonRejectedCount: nonRejectedCount,
            effectiveTarget: effectiveTarget(for: quest, specificDays: specificDays)
        )
    }

    static func nonRejectedLogsReachTarget(quest _: Quest, nonRejectedCount: Int, effectiveTarget: Int) -> Bool {
        let target = max(1, effectiveTarget)
        return nonRejectedCount >= target
    }

    static func credit(for quest: QuestCache, approvedCount: Int, effectiveTarget: Int) -> Decimal {
        credit(
            goldReward: quest.goldReward,
            targetCount: effectiveTarget,
            isAllOrNothing: quest.isAllOrNothing,
            approvedCount: approvedCount
        )
    }

    static func credit(for quest: QuestCache, approvedCount: Int, specificDays: [String]) -> Decimal {
        credit(
            for: quest,
            approvedCount: approvedCount,
            effectiveTarget: effectiveTarget(for: quest, specificDays: specificDays)
        )
    }

    static func creditAsDouble(for quest: QuestCache, approvedCount: Int, effectiveTarget: Int) -> Double {
        creditAsDouble(
            goldReward: quest.goldReward,
            targetCount: effectiveTarget,
            isAllOrNothing: quest.isAllOrNothing,
            approvedCount: approvedCount
        )
    }

    static func creditAsDouble(for quest: QuestCache, approvedCount: Int, specificDays: [String]) -> Double {
        creditAsDouble(
            for: quest,
            approvedCount: approvedCount,
            effectiveTarget: effectiveTarget(for: quest, specificDays: specificDays)
        )
    }

    static func credit(for quest: Quest, approvedCount: Int, effectiveTarget: Int) -> Decimal {
        credit(
            goldReward: quest.goldReward,
            targetCount: effectiveTarget,
            isAllOrNothing: quest.isAllOrNothing,
            approvedCount: approvedCount
        )
    }

    static func creditAsDouble(for quest: Quest, approvedCount: Int, effectiveTarget: Int) -> Double {
        creditAsDouble(
            goldReward: quest.goldReward,
            targetCount: effectiveTarget,
            isAllOrNothing: quest.isAllOrNothing,
            approvedCount: approvedCount
        )
    }

    static func netWeeklyGold(
        quests: [QuestCache],
        logs: [QuestCompletionCache],
        profileRecordName: String,
        payoutPolicy: PayoutPolicy?,
        weekRange: Range<Date>,
        templatesByID: [String: QuestTemplateCache] = [:]
    ) -> Double {
        let heroLogs = logs.filter { $0.completerRecordName == profileRecordName }
        let approvedLogs = heroLogs.filter {
            ($0.verificationStatusEnum == .autoApproved || $0.verificationStatusEnum == .verified) &&
                (weekRange.contains($0.weekOf) || weekRange.contains($0.completedDate))
        }

        var totalEarned = totalGold(for: quests, approvedLogs: approvedLogs, templatesByID: templatesByID)

        let assignedQuests = quests.filter {
            $0.assigneeRecordName == profileRecordName && weekRange.contains($0.weekOf)
        }

        let fullyCompletedCount = assignedQuests.filter { quest in
            let qLogs = approvedLogs.filter { $0.questRecordName == quest.recordName }
            // WHY day count wins: stale targetCount would zero all-or-nothing payouts incorrectly.
            let target = SpecificDaysHelper.effectiveTarget(for: quest, templatesByID: templatesByID)
            return isFullyCompleted(quest: quest, approvedCount: qLogs.count, effectiveTarget: target)
        }.count

        if payoutPolicy == .allOrNothing,
           !assignedQuests.isEmpty,
           fullyCompletedCount < assignedQuests.count
        {
            totalEarned = 0
        }

        return totalEarned
    }

    // MARK: - Pure Domain Gold Aggregation

    /// Pure gold summation over already-fetched Quest models.
    static func totalCredit(
        for quests: [Quest],
        logs: [QuestCompletion],
        templatesByID: [String: QuestTemplate] = [:]
    ) -> Double {
        let approved = logs.filter {
            $0.verificationStatus == .verified || $0.verificationStatus == .autoApproved
        }
        guard !approved.isEmpty else { return 0 }
        let questMap = Dictionary(uniqueKeysWithValues: quests.map { ($0.id.recordName, $0) })
        var countByName: [String: Int] = [:]
        for log in approved {
            countByName[log.quest.recordID.recordName, default: 0] += 1
        }
        var total = 0.0
        for (name, count) in countByName {
            if let quest = questMap[name] {
                // WHY day count wins: stale targetCount under-counts specific-days split rewards.
                let target = SpecificDaysHelper.effectiveTarget(for: quest, templatesByID: templatesByID)
                total += creditAsDouble(for: quest, approvedCount: count, effectiveTarget: target)
            } else {
                logger.warning("Missing quest \(name, privacy: .private) for gold proration")
            }
        }
        return total
    }
}
