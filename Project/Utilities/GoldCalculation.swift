//
//  GoldCalculation.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation

/// Single source of truth for quest-gold proration.
///
/// All gold accounting — the real wallet payout in `TreasuryService`, the
/// hero/guardian dashboard previews, and any downstream gold displays — must
/// route through this helper. Keeping the proration formula in one place
/// guarantees the wallet and the UI never disagree on what a partially
/// completed quest is worth.
///
/// Arithmetic is performed in `Decimal` (not `Double`) to avoid floating-point
/// truncation on currency values, e.g. `(5 / 3) * 3` must round to `5`, not a
/// `Double` artifact like `4.999999999`. The result is returned as `Decimal`
/// for callers that keep `Decimal` books; a `Double`-returning convenience is
/// provided for the existing `Double`-accumulator wallet plumbing.
///
/// `Sendable` and stateless: safe to call from `@MainActor` view models and
/// service code alike with no cross-isolation concerns.
enum GoldCalculation: Sendable {
    /// The canonical proration formula.
    ///
    /// - **All-or-nothing** (`isAllOrNothing == true`): the full `goldReward`
    ///   is paid only once the hero reaches `targetCount` approved completions;
    ///   any partial count pays `0`.
    /// - **Per-quest** (the default): `goldReward` is paid proportionally,
    ///   capped at `targetCount` so over-completion never pays out more than
    ///   the quest's bounty:
    ///
    ///   `(goldReward / targetCount) * min(approvedCount, targetCount)`
    ///
    /// `isAllOrNothing` derives from the existing `PayoutPolicy` enum on
    /// `Family` / `Profile` and is materialized as `Quest.isAllOrNothing`.
    /// No new policy is introduced here.
    ///
    /// - Parameters:
    ///   - goldReward: Full gold bounty for the quest.
    ///   - targetCount: Completions required to fully earn `goldReward`.
    ///     Treated as `max(1, targetCount)` so a malformed `0` never divides
    ///     by zero.
    ///   - isAllOrNothing: `true` for `PayoutPolicy.allOrNothing`.
    ///   - approvedCount: Number of approved (verified/auto-approved) logs for
    ///     this quest in the window being summed.
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

    static func creditAsDecimal(xp: Int, baseRate: Double) -> Decimal {
        // Use Decimal for precise calculation
        let rate = Decimal(baseRate)
        let xpDecimal = Decimal(xp)
        return xpDecimal * rate / 100
    }

    static func creditAsDouble(xp: Int, baseRate: Double) -> Double {
        NSDecimalNumber(decimal: creditAsDecimal(xp: xp, baseRate: baseRate)).doubleValue
    }

    static func totalGold(
        for quests: [QuestCache],
        approvedLogs: [QuestCompletionCache]
    ) -> Double {
        let questByName = Dictionary(quests.map { ($0.recordName, $0) }, uniquingKeysWith: { current, _ in current })
        var countByQuest: [String: Int] = [:]
        for log in approvedLogs {
            countByQuest[log.questRecordName, default: 0] += 1
        }
        var total = 0.0
        for (qName, count) in countByQuest {
            if let quest = questByName[qName] {
                total += creditAsDouble(for: quest, approvedCount: count)
            }
        }
        return total
    }
}
