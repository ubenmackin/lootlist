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
    ///
    /// - Parameters:
    ///   - goldReward: Total gold bounty for the quest.
    ///   - targetCount: Completions required to fully earn `goldReward`.
    ///   - isAllOrNothing: Whether full completion is required for any payout.
    ///   - approvedCount: Number of approved logs for this quest.
    /// - Returns: The gold amount to credit as a `Decimal`.
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

    /// `Double`-returning variant for wallet plumbing that accumulates gold
    /// into existing `Double` totals (e.g. `TreasuryService.sumGold`,
    /// dashboard breakdowns). The proration itself still runs in `Decimal`;
    /// the result is bridged through `NSDecimalNumber` so banker's rounding
    /// — not `Double` truncation — decides the last cent.
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

    /// Cumulative XP credit for a quest, prorated and capped at `xpReward`.
    ///
    /// - Parameters:
    ///   - xpReward: Full XP bounty for the quest.
    ///   - targetCount: Completions required to fully earn `xpReward`.
    ///   - isAllOrNothing: `true` for `PayoutPolicy.allOrNothing`.
    ///   - approvedCount: Number of approved logs for this quest.
    /// - Returns: The cumulative XP credit, capped at `xpReward`.
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
    ///
    /// - Parameters:
    ///   - quest: The quest being rewarded.
    ///   - approvedCount: Approved logs visible to the post-save recount.
    ///   - alreadyCredited: XP already banked for this quest by earlier completions.
    /// - Returns: The XP to grant for this completion, always `>= 0`.
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
        approvedLogs: [QuestCompletionCache]
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
                total += creditAsDouble(for: quest, approvedCount: count)
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

    /// Whether a quest's non-rejected logs (approved OR pending) already
    /// occupy every completion slot — the gate `QuestService.markComplete`
    /// uses to reject a new completion before the hero logs more. Guarded
    /// against `targetCount == 0` like every sibling completion check.
    static func nonRejectedLogsReachTarget(quest: QuestCache, nonRejectedCount: Int) -> Bool {
        let target = max(1, quest.targetCount)
        return nonRejectedCount >= target
    }

    static func nonRejectedLogsReachTarget(quest: Quest, nonRejectedCount: Int) -> Bool {
        let target = max(1, quest.targetCount)
        return nonRejectedCount >= target
    }

    static func netWeeklyGold(
        quests: [QuestCache],
        logs: [QuestCompletionCache],
        profileRecordName: String,
        payoutPolicy: PayoutPolicy?,
        weekRange: Range<Date>
    ) -> Double {
        let heroLogs = logs.filter { $0.completerRecordName == profileRecordName }
        let approvedLogs = heroLogs.filter {
            ($0.verificationStatusEnum == .autoApproved || $0.verificationStatusEnum == .verified) &&
                (weekRange.contains($0.weekOf) || weekRange.contains($0.completedDate))
        }

        var totalEarned = totalGold(for: quests, approvedLogs: approvedLogs)

        let assignedQuests = quests.filter {
            $0.assigneeRecordName == profileRecordName && weekRange.contains($0.weekOf)
        }

        let fullyCompletedCount = assignedQuests.filter { quest in
            let qLogs = approvedLogs.filter { $0.questRecordName == quest.recordName }
            return isFullyCompleted(quest: quest, approvedCount: qLogs.count)
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

    /// Pure gold summation over already-fetched `Quest` models. No cache or
    /// CloudKit access — callers must supply the quest records that
    /// correspond to `logs`. Missing quests are skipped (treated as 0) and
    /// logged at warning so CloudKit fetch gaps remain observable.
    static func totalCredit(for quests: [Quest], logs: [QuestCompletion]) -> Double {
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
                total += creditAsDouble(for: quest, approvedCount: count)
            } else {
                logger.warning("Missing quest \(name, privacy: .private) for gold proration")
            }
        }
        return total
    }
}
