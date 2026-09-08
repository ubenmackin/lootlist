//
//  GoldCalculation.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation
import os

/// Calculates quest reward proration in whole pennies using integer math.
enum GoldCalculation: Sendable {
    private static let logger = Logger(category: "GoldCalculation")

    /// WHY integer math: prorated splits round half up to whole pennies so
    /// wallet totals never accumulate floating-point drift.
    static func creditPennies(goldRewardPennies: Int64,
                              targetCount: Int,
                              isAllOrNothing: Bool,
                              approvedCount: Int) -> Int64
    {
        let safeTarget = max(1, targetCount)
        let capped = min(max(0, approvedCount), safeTarget)
        guard capped > 0 else { return 0 }
        if isAllOrNothing {
            return capped >= safeTarget ? max(0, goldRewardPennies) : 0
        }
        let reward = max(0, goldRewardPennies)
        return (reward * Int64(capped) + Int64(safeTarget / 2)) / Int64(safeTarget)
    }

    /// Computes prorated gold credit based on approved completion count and payout policy.
    static func credit(goldReward: Int64,
                       targetCount: Int,
                       isAllOrNothing: Bool,
                       approvedCount: Int) -> Int64
    {
        creditPennies(goldRewardPennies: goldReward,
                      targetCount: targetCount,
                      isAllOrNothing: isAllOrNothing,
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

    static func totalPennies(
        for quests: [QuestCache],
        approvedLogs: [QuestCompletionCache],
        templatesByID: [String: QuestTemplateCache] = [:]
    ) -> Int64 {
        let questByName = Dictionary(quests.map { ($0.recordName, $0) },
                                     uniquingKeysWith: { current, _ in current })
        var countByQuest: [String: Int] = [:]
        for log in approvedLogs {
            countByQuest[log.questRecordName, default: 0] += 1
        }
        var total: Int64 = 0
        for (qName, count) in countByQuest {
            if let quest = questByName[qName] {
                // WHY day count wins: stale targetCount under-counts specific-days split rewards.
                let target = SpecificDaysHelper.effectiveTarget(for: quest, templatesByID: templatesByID)
                total += creditPennies(for: quest, approvedCount: count, effectiveTarget: target)
            } else {
                logger.warning("Missing quest \(qName, privacy: .private) for gold proration")
            }
        }
        return total
    }

    static func isFullyCompleted(quest _: QuestCache, approvedCount: Int, effectiveTarget: Int) -> Bool {
        let target = max(1, effectiveTarget)
        return approvedCount >= target
    }

    static func isFullyCompleted(quest: QuestCache, approvedCount: Int, specificDays: [String]) -> Bool {
        isFullyCompleted(
            quest: quest,
            approvedCount: approvedCount,
            effectiveTarget: SpecificDaysHelper.effectiveTarget(for: quest, specificDays: specificDays)
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
            effectiveTarget: SpecificDaysHelper.effectiveTarget(for: quest, specificDays: specificDays)
        )
    }

    static func nonRejectedLogsReachTarget(quest _: Quest, nonRejectedCount: Int, effectiveTarget: Int) -> Bool {
        let target = max(1, effectiveTarget)
        return nonRejectedCount >= target
    }

    static func credit(for quest: QuestCache, approvedCount: Int, effectiveTarget: Int) -> Int64 {
        creditPennies(
            goldRewardPennies: quest.goldReward,
            targetCount: effectiveTarget,
            isAllOrNothing: quest.isAllOrNothing,
            approvedCount: approvedCount
        )
    }

    static func credit(for quest: QuestCache, approvedCount: Int, specificDays: [String]) -> Int64 {
        credit(
            for: quest,
            approvedCount: approvedCount,
            effectiveTarget: SpecificDaysHelper.effectiveTarget(for: quest, specificDays: specificDays)
        )
    }

    static func creditPennies(for quest: QuestCache, approvedCount: Int, effectiveTarget: Int) -> Int64 {
        creditPennies(
            goldRewardPennies: quest.goldReward,
            targetCount: effectiveTarget,
            isAllOrNothing: quest.isAllOrNothing,
            approvedCount: approvedCount
        )
    }

    static func creditPennies(for quest: QuestCache, approvedCount: Int, specificDays: [String]) -> Int64 {
        creditPennies(
            for: quest,
            approvedCount: approvedCount,
            effectiveTarget: SpecificDaysHelper.effectiveTarget(for: quest, specificDays: specificDays)
        )
    }

    static func credit(for quest: Quest, approvedCount: Int, effectiveTarget: Int) -> Int64 {
        creditPennies(
            goldRewardPennies: quest.goldReward,
            targetCount: effectiveTarget,
            isAllOrNothing: quest.isAllOrNothing,
            approvedCount: approvedCount
        )
    }

    static func creditPennies(for quest: Quest, approvedCount: Int, effectiveTarget: Int) -> Int64 {
        creditPennies(
            goldRewardPennies: quest.goldReward,
            targetCount: effectiveTarget,
            isAllOrNothing: quest.isAllOrNothing,
            approvedCount: approvedCount
        )
    }

    static func netWeeklyPennies(
        quests: [QuestCache],
        logs: [QuestCompletionCache],
        profileRecordName: String,
        payoutPolicy: PayoutPolicy?,
        weekRange: Range<Date>,
        templatesByID: [String: QuestTemplateCache] = [:]
    ) -> Int64 {
        let heroLogs = logs.filter { $0.completerRecordName == profileRecordName }
        let approvedLogs = heroLogs.filter {
            ($0.verificationStatusEnum == .autoApproved || $0.verificationStatusEnum == .verified) &&
                (weekRange.contains($0.weekOf) || weekRange.contains($0.completedDate))
        }

        var totalEarned = totalPennies(for: quests, approvedLogs: approvedLogs, templatesByID: templatesByID)

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

    /// Pure pennies summation over already-fetched Quest models.
    static func totalCreditPennies(
        for quests: [Quest],
        logs: [QuestCompletion],
        templatesByID: [String: QuestTemplate] = [:]
    ) -> Int64 {
        let approved = logs.filter {
            $0.verificationStatus == .verified || $0.verificationStatus == .autoApproved
        }
        guard !approved.isEmpty else { return 0 }
        let questMap = Dictionary(uniqueKeysWithValues: quests.map { ($0.id.recordName, $0) })
        var countByName: [String: Int] = [:]
        for log in approved {
            countByName[log.quest.recordID.recordName, default: 0] += 1
        }
        var total: Int64 = 0
        for (name, count) in countByName {
            if let quest = questMap[name] {
                // WHY day count wins: stale targetCount under-counts specific-days split rewards.
                let target = SpecificDaysHelper.effectiveTarget(for: quest, templatesByID: templatesByID)
                total += creditPennies(for: quest, approvedCount: count, effectiveTarget: target)
            } else {
                logger.warning("Missing quest \(name, privacy: .private) for gold proration")
            }
        }
        return total
    }

    // MARK: - Legacy Double shims (pennies-backed)

    /// WHY shim: historic Double callers stay compiling while single-sourcing math in pennies.
    static func creditAsDouble(goldReward: Double, targetCount: Int, isAllOrNothing: Bool, approvedCount: Int) -> Double {
        Double(creditPennies(
            goldRewardPennies: CurrencyFormatter.dollarsToPennies(goldReward),
            targetCount: targetCount,
            isAllOrNothing: isAllOrNothing,
            approvedCount: approvedCount
        )) / 100.0
    }

    static func creditAsDouble(for quest: QuestCache, approvedCount: Int, effectiveTarget: Int) -> Double {
        Double(creditPennies(for: quest, approvedCount: approvedCount, effectiveTarget: effectiveTarget)) / 100.0
    }

    static func creditAsDouble(for quest: QuestCache, approvedCount: Int, specificDays: [String]) -> Double {
        Double(creditPennies(for: quest, approvedCount: approvedCount, specificDays: specificDays)) / 100.0
    }

    static func creditAsDouble(for quest: Quest, approvedCount: Int, effectiveTarget: Int) -> Double {
        Double(creditPennies(for: quest, approvedCount: approvedCount, effectiveTarget: effectiveTarget)) / 100.0
    }

    static func totalGold(for quests: [QuestCache], approvedLogs: [QuestCompletionCache], templatesByID: [String: QuestTemplateCache] = [:]) -> Double {
        Double(totalPennies(for: quests, approvedLogs: approvedLogs, templatesByID: templatesByID)) / 100.0
    }

    static func netWeeklyGold(
        quests: [QuestCache],
        logs: [QuestCompletionCache],
        profileRecordName: String,
        payoutPolicy: PayoutPolicy?,
        weekRange: Range<Date>,
        templatesByID: [String: QuestTemplateCache] = [:]
    ) -> Double {
        Double(netWeeklyPennies(quests: quests, logs: logs, profileRecordName: profileRecordName, payoutPolicy: payoutPolicy, weekRange: weekRange, templatesByID: templatesByID)) /
            100.0
    }

    static func totalCredit(for quests: [Quest], logs: [QuestCompletion], templatesByID: [String: QuestTemplate] = [:]) -> Double {
        Double(totalCreditPennies(for: quests, logs: logs, templatesByID: templatesByID)) / 100.0
    }
}
