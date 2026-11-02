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
        // WHY truncate: fractional XP drops with no Double round-trip.
        var rounded = Decimal()
        var source = total
        NSDecimalRound(&rounded, &source, 0, .down)
        return NSDecimalNumber(decimal: rounded).intValue
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

    static func isFullyCompleted(quest _: Quest, approvedCount: Int, effectiveTarget: Int) -> Bool {
        let target = max(1, effectiveTarget)
        return approvedCount >= target
    }

    static func nonRejectedLogsReachTarget(quest _: QuestCache, nonRejectedCount: Int, effectiveTarget: Int) -> Bool {
        let target = max(1, effectiveTarget)
        return nonRejectedCount >= target
    }

    static func nonRejectedLogsReachTarget(quest _: Quest, nonRejectedCount: Int, effectiveTarget: Int) -> Bool {
        let target = max(1, effectiveTarget)
        return nonRejectedCount >= target
    }

    static func creditPennies(for quest: QuestCache, approvedCount: Int, effectiveTarget: Int) -> Int64 {
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
        // WHY weekOf-only: matches fetchQuestLogs so counts and gold never diverge.
        let approvedLogs = heroLogs.filter {
            ($0.verificationStatusEnum == .autoApproved || $0.verificationStatusEnum == .verified) &&
                weekRange.contains($0.weekOf)
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

    /// WHY separate pools: the quest share caps at the snapshot so merge skew in paidAmount
    /// can never eat into the bonus remainder drawn from the same total.
    static func settledBonusSnapshot(totalEarned: Int64, questPaid: Int64) -> Int64 {
        let questShare = min(max(Int64(0), questPaid), max(Int64(0), totalEarned))
        return max(Int64(0), totalEarned - questShare)
    }

    /// WHY quest-only pending: payout amount is live quest gold minus settled paidAmount floored at zero.
    static func pendingQuestRemainder(liveQuestGold: Int64, settledPaid: Int64) -> Int64 {
        max(Int64(0), liveQuestGold - settledPaid)
    }

    /// WHY total display: quest remainder plus bonus remainder for weekly breakdown totals; pending payout uses pendingQuestRemainder quest-only.
    static func pendingRemainder(liveQuestGold: Int64,
                                 liveBonusGold: Int64,
                                 settledPaid: Int64,
                                 totalEarnedSnapshot: Int64,
                                 isPaid: Bool) -> Int64
    {
        let questGold = pendingQuestRemainder(liveQuestGold: liveQuestGold, settledPaid: settledPaid)
        let bonusGold: Int64 = if isPaid {
            max(Int64(0), liveBonusGold - settledBonusSnapshot(totalEarned: totalEarnedSnapshot, questPaid: settledPaid))
        } else {
            liveBonusGold
        }
        return questGold + bonusGold
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

    // MARK: - Real-Time Settlement

    /// One approved event's marginal gold slice for real-time settlement.
    struct RealTimeAttribution: Sendable {
        let completionRecordName: String
        let questRecordName: String
        let pennies: Int64
    }

    /// WHY cumulative deltas: slice k is `credit(k) - credit(k-1)` so the slices always sum to
    /// the same weekly total and each event settles append-only. Zero-marginal slices
    /// (all-or-nothing quests before the target) are dropped; the completing
    /// event carries the full reward.
    static func realTimeAttributions(
        quests: [Quest],
        logs: [QuestCompletion],
        templatesByID: [String: QuestTemplate]
    ) -> [RealTimeAttribution] {
        let approved = logs.filter {
            $0.verificationStatus == .verified || $0.verificationStatus == .autoApproved
        }
        guard !approved.isEmpty else { return [] }

        var logsByQuest: [String: [QuestCompletion]] = [:]
        for log in approved {
            logsByQuest[log.quest.recordID.recordName, default: []].append(log)
        }

        var attributions: [RealTimeAttribution] = []
        for quest in quests {
            let name = quest.id.recordName
            guard var group = logsByQuest[name] else { continue }
            // WHY recordName tie-break: same-instant completions must settle one stable order across devices.
            group.sort {
                ($0.completedDate, $0.id.recordName) < ($1.completedDate, $1.id.recordName)
            }
            let target = SpecificDaysHelper.effectiveTarget(for: quest, templatesByID: templatesByID)
            for (index, log) in group.enumerated() {
                let current = creditPennies(for: quest, approvedCount: index + 1, effectiveTarget: target)
                let previous = creditPennies(for: quest, approvedCount: index, effectiveTarget: target)
                let pennies = current - previous
                guard pennies > 0 else { continue }
                attributions.append(RealTimeAttribution(
                    completionRecordName: log.id.recordName,
                    questRecordName: name,
                    pennies: pennies
                ))
            }
        }

        let questNames = Set(quests.map(\.id.recordName))
        for name in logsByQuest.keys.sorted() where !questNames.contains(name) {
            logger.warning("Missing quest \(name, privacy: .private) for gold proration")
        }

        return attributions
    }
}
