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
    /// Gold credit routes through the shared `GoldCalculation` helper — the
    /// same one `TreasuryService.sumGold` uses — so the reward step and the
    /// wallet never disagree on a partially completed quest. XP routes through
    /// the same targetCount-aware proration (`GoldCalculation.xpCredit`) so
    /// over-completion (stale cache / concurrent devices) can never mint
    /// duplicate XP beyond the quest bounty. The persisted `QuestCompletion`
    /// record remains the credit TreasuryService sums; no parallel wallet
    /// write happens here.
    ///
    /// The XP grant is ANCHORED TO CLOUDKIT RECORDS:
    /// `QuestCompletion.xpCredited` is the per-record idempotency marker (each
    /// approved completion is rewarded at most once) and `Quest.xpBanked` is
    /// the server-authoritative monotonic per-quest banked total. Both live on
    /// CloudKit records in the family zone — shared across devices — so a
    /// concurrent cross-device completion whose post-save recount sees only its
    /// own log is still capped by the banked total the winning device wrote.
    /// The `xpBanked` write-back is serialized with CloudKit's change-tag
    /// optimistic concurrency (`serverRecordChanged` → re-fetch → recompute →
    /// retry), so two devices racing to bank the same marginal can never both
    /// mint it. No UserDefaults ledger exists anywhere.
    @discardableResult
    func applyReward(for quest: Quest, to hero: Profile, completion: QuestCompletion) async throws -> Double {
        // Internal-only authorization guard: the reward step is invoked after a
        // caller path has already validated authorization (`markComplete` for
        // an auto-approved self-completion, or `verify` for a parent-verified
        // completion). The acting session must be the credited hero theirself
        // OR a parent acting on the hero's behalf (the established
        // `acting.id == hero.id || acting.role.isParent` pattern); an
        // unrelated, non-parent stranger (or a direct call bypassing the
        // guarded entry points) returns zero rather than minting rewards to a
        // profile it is not authenticated as.
        guard let acting = appState?.currentProfile,
              acting.id == hero.id || acting.role.isParent
        else {
            return 0
        }
        // Read existing logs cache-first to compute the approved count for the
        // prorated gold AND the capped XP delta. This read runs POST-save
        // (never on the pre-write critical path). The save just succeeded, so
        // this completion is on the server; a transient read failure must not
        // starve a legitimate completion of its reward, so fall back to
        // treating this single completion as the approved count.
        let logs = await (try? fetchQuestLogs(forQuest: quest, useCache: true)) ?? []
        let approvedCount = max(1, logs.filter(\.verificationStatus.countsTowardCompletion).count)

        // Per-record idempotency: this completion's reward step has already
        // settled (a retry, a re-run through another path, or a concurrent
        // duplicate) — grant zero additional XP. The gold amount is derived
        // independently by `TreasuryService.sumGold` (count-capped per quest),
        // so returning it unchanged stays correct.
        if completion.xpCredited == nil {
            // Claim the marginal XP against the server-authoritative
            // `Quest.xpBanked` cap (CAS-serialized), grant exactly what was
            // claimed, then persist the per-record marker so any re-run of this
            // completion's reward step grants zero.
            if let xpGain = await bankXP(for: quest, to: hero, approvedCount: approvedCount, completion: completion) {
                await stampCompletionCredit(completion, xpGain: xpGain)
            }
        }

        let creditedGold = GoldCalculation.creditAsDouble(for: quest, approvedCount: approvedCount)

        if hero.payoutPolicy == .realTime, creditedGold > 0, let treasuryService {
            let questFamilyID = quest.family.recordID
            let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "QuestService")
            Task { [logger] in
                do {
                    // Cache-first family fetch: the real-time settlement hot
                    // path is served from the family's cached record when its
                    // cache is fresh, so no CloudKit round-trip is issued for a
                    // record the cache already holds. A stale or absent family
                    // cache falls through to a single fetch that write-throughs
                    // the cache.
                    let family: Family
                    if let cached = cacheService?.fetchFamily(recordName: questFamilyID.recordName),
                       cacheService?.isCacheFresh(familyRecordName: questFamilyID.recordName, type: .family) == true
                    {
                        family = cached.toFamily(zoneID: cloudKit.resolvedZoneID)
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

    /// Bounded retries for the change-tag CAS write-back of `Quest.xpBanked`.
    /// Two devices racing to bank XP both start from the same authoritative
    /// total; the first save and the loser's save fails with
    /// `serverRecordChanged`, after which it re-fetches the quest, recomputes
    /// the marginal against the updated total, and retries — so the quest's
    /// XP bounty can never be minted more than once.
    private static let maxXPBankAttempts = 3

    /// Claims the marginal XP for one completion against the
    /// server-authoritative `Quest.xpBanked` cap, using CloudKit's change-tag
    /// optimistic concurrency to serialize cross-device XP grants.
    ///
    /// 1. Resolve the freshest authoritative quest using the family's quest
    ///    cache when fresh (a completed sync pass propagates `xpBanked`),
    ///    otherwise a single CloudKit fetch. The passed-in `quest` may be stale
    ///    (another device banked since it was read) and is used only as a
    ///    last-resort fallback when the fetch fails.
    /// 2. Compute the marginal grant via `GoldCalculation.marginalXPCredit`
    ///    against the authoritative total.
    /// 3. Write `xpBanked = banked + marginal`, preserving every other quest
    ///    field. On `serverRecordChanged` (CloudKit's CAS conflict) re-fetch
    ///    the authoritative quest, recompute against the new total, and retry
    ///    — bounded, so two devices racing to bank the same marginal can never
    ///    both mint it.
    /// 4. Grant exactly the claimed XP via `xpService.addXP`.
    ///
    /// Returns the XP granted (`0` when the bounty is already fully banked),
    /// or `nil` if the CAS write-back failed to settle (e.g. retries exhausted).
    private func bankXP(for quest: Quest, to hero: Profile, approvedCount: Int, completion _: QuestCompletion) async -> Int? {
        let questRecordName = quest.id.recordName
        let inFlightKey = questRecordName

        // Register the optimistic window so a background sync skips this
        // quest row while the CAS write-back is in flight.
        let registry = cacheService?.inFlightRegistry
        await registry?.register(inFlightKey)

        var currentQuest = await resolveAuthoritativeQuest(quest)
        var attempt = 0
        while attempt < Self.maxXPBankAttempts {
            attempt += 1
            let remaining = GoldCalculation.marginalXPCredit(
                for: currentQuest,
                approvedCount: approvedCount,
                alreadyCredited: currentQuest.xpBanked
            )
            if remaining == 0 {
                await registry?.deregister(inFlightKey)
                return 0
            }

            // Mutate ONLY the banked total — every other quest field (and the
            // change tag) comes from the authoritative record untouched.
            var updated = currentQuest
            updated.xpBanked = currentQuest.xpBanked + remaining
            do {
                let saved = try await cloudKit.save(updated)
                cacheService?.upsertQuest(saved)
                do {
                    try await xpService.addXP(remaining, to: hero)
                } catch {
                    if let reverted = try? await cloudKit.save(currentQuest) {
                        cacheService?.upsertQuest(reverted)
                    } else {
                        cacheService?.upsertQuest(currentQuest)
                    }
                    throw error
                }
                await registry?.deregister(inFlightKey)
                return remaining
            } catch let error as CloudKitServiceError where error == .serverRecordChanged {
                // Another device banked first: re-fetch the authoritative quest
                // and recompute the marginal against the updated total.
                guard let fresh = try? await cloudKit.fetch(Quest.self, id: quest.id) else {
                    await registry?.deregister(inFlightKey)
                    return nil
                }
                cacheService?.upsertQuest(fresh)
                currentQuest = fresh
            } catch {
                await registry?.deregister(inFlightKey)
                return nil
            }
        }
        await registry?.deregister(inFlightKey)
        return nil
    }

    /// Resolves the freshest authoritative `Quest` for the XP banking step.
    /// Prefers the family's quest cache when fresh, falling back to a single
    /// CloudKit fetch when the cache is stale or partial. The passed-in
    /// `quest` is used only as a last-resort fallback when the fetch fails
    /// (a transient read failure must not starve a legitimate completion of
    /// its reward).
    private func resolveAuthoritativeQuest(_ quest: Quest) async -> Quest {
        let familyName = quest.family.recordID.recordName
        if let cache = cacheService,
           cache.isCacheFresh(familyRecordName: familyName, type: .quest),
           let cached = cache.fetchQuests(family: familyName)
           .first(where: { $0.recordName == quest.id.recordName })
        {
            return cached.toQuest(zoneID: cloudKit.resolvedZoneID)
        }
        if let fresh = try? await cloudKit.fetch(Quest.self, id: quest.id) {
            cacheService?.upsertQuest(fresh)
            return fresh
        }
        return quest
    }

    /// Persists the per-record idempotency marker: `QuestCompletion.xpCredited`
    /// records the XP this completion's reward step settled (`0` when capped),
    /// so a re-run of the reward step for this completion grants zero.
    ///
    /// Only invoked when `bankXP` returned a non-nil grant — i.e. the CAS
    /// write-back settled (whether it banked marginal XP or returned `0` for a
    /// legitimately already-capped bounty). When `bankXP` returns `nil` (CAS
    /// retries exhausted without settling), `applyReward` DOES NOT call this
    /// — `xpCredited` stays `nil` so a future reward-step re-run can retry the
    /// CAS rather than being permanently suppressed by a spurious `0` stamp.
    /// This is what distinguishes "legitimately capped" (stamp `0`) from
    /// "exhausted" (leave `nil`). The quest-level `xpBanked` cap remains the
    /// authoritative double-mint guard.
    private func stampCompletionCredit(_ completion: QuestCompletion, xpGain: Int) async {
        var updated = completion
        updated.xpCredited = xpGain
        guard let stamped = try? await cloudKit.save(updated) else { return }
        cacheService?.upsertQuestCompletion(stamped)
    }
}
