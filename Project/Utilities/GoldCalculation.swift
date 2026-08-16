//
//  GoldCalculation.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation

// Single source of truth for quest-gold proration.

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

    /// XP credit for a quest, mirroring the gold proration above so XP and
    /// gold can never disagree on a partially completed quest.
    ///
    /// This is the economy cap for `QuestService.applyReward`: the cumulative
    /// XP credit for a quest is `xpReward` at most, and over-completion
    /// (`approvedCount > targetCount`) never increases it. Callers that grant
    /// XP per approved completion must grant the *marginal* amount
    /// (`xpCredit(N) - xpCredit(N-1)`) so a quest's total XP payout across all
    /// approved completions — including completions racing in from a stale
    /// cache or a second device — never exceeds the quest's bounty.
    ///
    /// The plain marginal is only correct when the recount's `approvedCount`
    /// is accurate. Under a concurrent cross-device completion the post-save
    /// recount can omit the other device's just-saved completion (a fresh
    /// cache serves only the local log), so both devices would compute the
    /// same marginal and mint 2× the bounty. Reward callers must therefore
    /// pass the quest's already-banked credit into
    /// `marginalXPCredit(for:approvedCount:alreadyCredited:)`, which caps the
    /// grant at the remaining bounty.
    ///
    /// Arithmetic mirrors `credit`: `Decimal` division so
    /// `(xpReward / targetCount) * targetCount` rounds back to `xpReward`
    /// exactly; the result is bridged through `Double` (like `creditAsDouble`)
    /// so odd divisions never truncate a quest's bounty.
    ///
    /// - Parameters:
    ///   - xpReward: Full XP bounty for the quest.
    ///   - targetCount: Completions required to fully earn `xpReward`.
    ///     Treated as `max(1, targetCount)` so a malformed `0` never divides
    ///     by zero.
    ///   - isAllOrNothing: `true` for `PayoutPolicy.allOrNothing`.
    ///   - approvedCount: Number of approved (verified/auto-approved) logs for
    ///     this quest.
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

    /// The XP grant for ONE approved completion of a quest, capped so the
    /// quest's total XP payout can never exceed its bounty.
    ///
    /// The plain marginal (`xpCredit(N) - xpCredit(N-1)`) is correct only when
    /// the recount's `approvedCount` is accurate. When a concurrent
    /// cross-device completion races the post-save recount, each device can
    /// observe only its own completion and both would grant the same full
    /// marginal. `alreadyCredited` — the XP already banked for this quest by
    /// earlier reward steps (the quest-scoped credit ledger) — bounds the
    /// grant to the remaining bounty, so the grant is
    /// `min(marginal, xpCredit(N) - alreadyCredited)`.
    ///
    /// - Parameters:
    ///   - quest: The quest being rewarded.
    ///   - approvedCount: Approved logs visible to the post-save recount
    ///     (`max(1, ...)` semantics handled by the caller).
    ///   - alreadyCredited: XP already banked for this quest by earlier reward
    ///     steps, from the quest-scoped credit ledger.
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
        // Use Decimal for precise calculation
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

    /// Single source of truth for "sum gold across logs, cache-first with per-id CK fallback".
    /// Used by TreasuryService.sumGold and QuestService+QuestLogs.earnedThisWeek to
    /// prevent duplicated cache-then-CK-fallback-then-prorate gold summation.
    static func totalCredit(
        logs: [QuestCompletion],
        cacheService: CacheService?,
        cloudKit: any CloudKitServiceProtocol,
        family: Family? = nil,
        calendar _: Calendar = .iso8601UTC
    ) async -> Double {
        let completedLogs = logs.filter { $0.verificationStatus == .verified || $0.verificationStatus == .autoApproved }
        guard !completedLogs.isEmpty else { return 0 }

        let uniqueQuestIDs = Array(Set(completedLogs.map(\.quest.recordID)))
        var questMap: [CKRecord.ID: Quest] = [:]

        var isFresh = false
        if let cache = cacheService {
            let familyName = family?.id.recordName
            isFresh = await MainActor.run {
                if let familyName {
                    return cache.isCacheFresh(familyRecordName: familyName, type: .quest)
                }
                return false
            }
            if isFresh {
                let quests = await MainActor.run {
                    let zoneID = family?.id.zoneID ?? completedLogs.first?.quest.recordID.zoneID ?? CKRecordZone.default().zoneID
                    return cache.fetchQuests(family: familyName).map { $0.toQuest(zoneID: zoneID) }
                }
                for quest in quests {
                    questMap[quest.id] = quest
                }
            }
        }

        if !isFresh {
            let missingIDs = uniqueQuestIDs.filter { questID in
                questMap[questID] == nil && !questMap.keys.contains { $0.recordName == questID.recordName }
            }

            if !missingIDs.isEmpty {
                for questID in missingIDs {
                    if let fetched = try? await cloudKit.fetch(Quest.self, id: questID) {
                        questMap[questID] = fetched
                        questMap[fetched.id] = fetched
                    }
                }
            }
        }

        var approvedCountByQuest: [CKRecord.ID: Int] = [:]
        for log in completedLogs {
            approvedCountByQuest[log.quest.recordID, default: 0] += 1
        }

        var total: Double = 0
        for (questID, approvedCount) in approvedCountByQuest {
            if let quest = questMap[questID] ?? questMap.values.first(where: { $0.id.recordName == questID.recordName }) {
                total += creditAsDouble(for: quest, approvedCount: approvedCount)
            }
        }
        return total
    }
}
