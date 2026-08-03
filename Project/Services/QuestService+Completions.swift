//
//  QuestService+Completions.swift
//  LootList
//
//  Created by Ben Mackin on 8/1/26.
//

import CloudKit
import Foundation
import Synchronization

// MARK: - Quest Completions & Verification

extension QuestService {
    @discardableResult
    func markComplete(quest: Quest, by profile: Profile, at completedDate: Date = Date()) async throws -> QuestCompletion {
        let questName = quest.id.recordName

        // Local double-submit guard: NO CloudKit round-trip on the
        // pre-write critical path. A second tap while a completion for this
        // quest is still being saved is a no-op (toast), not a duplicate.
        if inFlightCompletions.withLock({ $0.contains(questName) }) {
            toastManager?.show(
                message: "This quest is already being completed.",
                type: .info
            )
            throw QuestServiceError.alreadyInFlight
        }
        inFlightCompletions.withLock { _ = $0.insert(questName) }
        defer { inFlightCompletions.withLock { _ = $0.remove(questName) } }

        // Fast-path: read existing logs cache-first for 0ms response. This is
        // a STRICTLY local read — it never falls through to a CloudKit query on
        // the pre-write critical path. A cold cache simply means "no local
        // evidence of completion" and the write proceeds.
        let cachedLogs = cachedQuestLogs(forQuest: quest)
        let cachedNonRejectedCount = cachedLogs.filter { $0.verificationStatus != .rejected }.count
        let target = max(1, quest.targetCount)
        if cachedNonRejectedCount >= target {
            throw QuestServiceError.alreadyCompleted
        }

        let log = QuestCompletion(
            quest: CKRecord.Reference(recordID: quest.id, action: .none),
            completedBy: CKRecord.Reference(recordID: profile.id, action: .none),
            approvalMode: quest.approvalMode,
            weekOf: quest.weekOf,
            family: quest.family
        )

        var editable = log
        editable.completedDate = completedDate

        // Register the optimistic window so a background sync skips this row.
        let registry = cacheService?.inFlightRegistry
        await registry?.register(editable.id.recordName)

        // Optimistic local write first
        cacheService?.upsertQuestCompletion(editable)

        do {
            let saved = try await cloudKit.save(editable)
            cacheService?.upsertQuestCompletion(saved)

            switch quest.approvalMode {
            case .autoApprove:
                try await applyReward(for: quest, to: profile, completion: saved)
            case .parentVerify:
                if let notificationService,
                   let parent = try? await cloudKit.fetch(Profile.self, id: quest.createdBy.recordID)
                {
                    Task { @Sendable in
                        try? await notificationService.sendQuestNeedsReview(questLog: saved, to: parent)
                    }
                }
            }

            await registry?.deregister(editable.id.recordName)
            return saved
        } catch {
            await handleSaveFailure(
                recordID: editable.id,
                fetchCurrentTag: { self.cacheService?.fetchQuestCompletions(family: quest.family.recordID.recordName)
                    .first(where: { $0.recordName == editable.id.recordName })?.changeTag
                },
                upsert: { self.cacheService?.upsertQuestCompletion($0) },
                invalidate: { self.cacheService?.invalidateQuestCompletion(recordName: $0) },
                error: error
            )
            await registry?.deregister(editable.id.recordName)
            throw error
        }
    }

    @discardableResult
    func verify(questLog: QuestCompletion, by parent: Profile) async throws -> QuestCompletion {
        guard questLog.verificationStatus == .pending else {
            throw QuestServiceError.alreadyResolved(questLog.verificationStatus.rawValue)
        }

        var updated = questLog
        updated.verificationStatus = .verified
        updated.verifiedBy = CKRecord.Reference(recordID: parent.id, action: .none)
        updated.verifiedDate = Date()

        let name = questLog.id.recordName
        let snapshot = cacheService?.fetchQuestCompletions(family: questLog.family.recordID.recordName).first(where: { $0.recordName == name })

        let preMutationChangeTag = snapshot?.changeTag
        // changeTag rehydrated from cache row per toX(zoneID:), safe for use in ConcurrentEditDetector.
        let snapshotCompletion: QuestCompletion? = snapshot?.toQuestCompletion(zoneID: cloudKit.resolvedZoneID)

        // Register the optimistic window so a background sync skips this row.
        let registry = cacheService?.inFlightRegistry
        await registry?.register(name)

        cacheService?.upsertQuestCompletion(updated)
        do {
            let saved = try await cloudKit.save(updated)
            cacheService?.upsertQuestCompletion(saved)

            // Cache-first quest + hero resolution: CloudKit is only consulted
            // when the family's quest/profile cache is stale or partial.
            let quest = try await resolveQuest(for: questLog)
            let hero = try await resolveHero(for: questLog)
            let creditedGold = try await applyReward(for: quest, to: hero, completion: saved)

            if let notificationService {
                Task { @Sendable in
                    let goldText = NumberFormatter.goldFormatter
                        .string(from: NSNumber(value: creditedGold)) ?? "\(creditedGold)"
                    try? await notificationService.send(
                        .questCompleted,
                        to: hero,
                        title: "🏆 Quest Verified!",
                        body: "Your quest was verified! You earned \(goldText) gold."
                    )
                }
            }

            await registry?.deregister(name)
            return saved
        } catch {
            await handleSaveFailure(
                recordID: questLog.id,
                preMutationChangeTag: preMutationChangeTag,
                snapshot: snapshotCompletion,
                fetchCurrentTag: { self.cacheService?.fetchQuestCompletions(family: questLog.family.recordID.recordName)
                    .first(where: { $0.recordName == name })?.changeTag
                },
                upsert: { self.cacheService?.upsertQuestCompletion($0) },
                invalidate: { self.cacheService?.invalidateQuestCompletion(recordName: $0) },
                error: error
            )
            await registry?.deregister(name)
            throw error
        }
    }

    @discardableResult
    func reject(questLog: QuestCompletion, by parent: Profile) async throws -> QuestCompletion {
        guard questLog.verificationStatus == .pending else {
            throw QuestServiceError.alreadyResolved(questLog.verificationStatus.rawValue)
        }

        var updated = questLog
        updated.verificationStatus = .rejected
        updated.verifiedBy = CKRecord.Reference(recordID: parent.id, action: .none)
        updated.verifiedDate = Date()

        let name = questLog.id.recordName
        let snapshot = cacheService?.fetchQuestCompletions(family: questLog.family.recordID.recordName).first(where: { $0.recordName == name })

        let preMutationChangeTag = snapshot?.changeTag
        // changeTag rehydrated from cache row per toX(zoneID:), safe for use in ConcurrentEditDetector.
        let snapshotCompletion: QuestCompletion? = snapshot?.toQuestCompletion(zoneID: cloudKit.resolvedZoneID)

        // Register the optimistic window so a background sync skips this row.
        let registry = cacheService?.inFlightRegistry
        await registry?.register(name)

        cacheService?.upsertQuestCompletion(updated)
        do {
            let saved = try await cloudKit.save(updated)
            cacheService?.upsertQuestCompletion(saved)
            await registry?.deregister(name)
            return saved
        } catch {
            await handleSaveFailure(
                recordID: questLog.id,
                preMutationChangeTag: preMutationChangeTag,
                snapshot: snapshotCompletion,
                fetchCurrentTag: { self.cacheService?.fetchQuestCompletions(family: questLog.family.recordID.recordName)
                    .first(where: { $0.recordName == name })?.changeTag
                },
                upsert: { self.cacheService?.upsertQuestCompletion($0) },
                invalidate: { self.cacheService?.invalidateQuestCompletion(recordName: $0) },
                error: error
            )
            await registry?.deregister(name)
            throw error
        }
    }

    func fetchStreak(for profile: Profile) async throws -> Int {
        let logs = try await fetchQuestLogs(for: profile)
        guard !logs.isEmpty else { return 0 }

        let daySet: Set<Date> = Set(logs.compactMap { log -> Date? in
            guard log.verificationStatus == .autoApproved || log.verificationStatus == .verified else { return nil }
            return calendar.dateInterval(of: .day, for: log.completedDate)?.start
        })

        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let anchor = daySet.contains(today) ? today
            : (daySet.contains(yesterday) ? yesterday : nil)
        guard let anchor else { return 0 }

        var streak = 0
        var cursor = anchor

        while daySet.contains(cursor) {
            streak += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        return streak
    }

    func earnedThisWeek(profile: Profile, weekOf: Date) async throws -> Double {
        let payoutDay = effectivePayoutDay(for: profile)
        let normalizedWeek = QuestService.startOfWeek(for: weekOf, payoutDay: payoutDay)
        let logs = try await fetchQuestLogs(for: profile)
            .filter { $0.weekOf == normalizedWeek
                && ($0.verificationStatus == .autoApproved
                    || $0.verificationStatus == .verified)
            }

        guard !logs.isEmpty else { return 0 }

        let questIDs = Array(Set(logs.map(\.quest.recordID)))
        var questMap: [CKRecord.ID: Quest] = [:]

        // Cache-first: build a lookup dictionary from the family's cached
        // quests.  Only quest IDs absent from the cache fall through to the
        // per-ID CloudKit fetch below (genuine cache miss).
        if let cache = cacheService,
           let familyName = logs.first?.family.recordID.recordName
        {
            let zoneID = cloudKit.resolvedZoneID
            for row in cache.fetchQuests(family: familyName) {
                let quest = row.toQuest(zoneID: zoneID)
                questMap[quest.id] = quest
            }
        }

        let missingIDs = questIDs.filter { questMap[$0] == nil }

        // CK fallback ONLY for cache-miss IDs (gracefully skipping deleted/missing quests).
        for questID in missingIDs {
            if let fetched = try? await cloudKit.fetch(Quest.self, id: questID) {
                questMap[questID] = fetched
            }
        }

        // Group approved logs by quest and route gold credit through the
        // shared `GoldCalculation` helper — the same one
        // `TreasuryService.sumGold` uses — so this weekly total and the wallet
        // never disagree on a partially completed quest. The proration is
        // per-quest (approvedCount per quest * goldReward / targetCount,
        // capped by `isAllOrNothing`), so the helper is invoked once per
        // quest with the full approved count for that quest.
        var approvedCountByQuest: [CKRecord.ID: Int] = [:]
        for log in logs {
            approvedCountByQuest[log.quest.recordID, default: 0] += 1
        }

        var total: Double = 0
        for (questID, approvedCount) in approvedCountByQuest {
            if let quest = questMap[questID] {
                total += GoldCalculation.creditAsDouble(for: quest,
                                                        approvedCount: approvedCount)
            }
        }
        return total
    }

    /// Cache-first read. Background refresh handled by SyncEngine via push notifications.
    func fetchQuestLogs(forQuest quest: Quest, useCache: Bool = true) async throws -> [QuestCompletion] {
        if useCache, let cache = cacheService {
            let questName = quest.id.recordName
            let familyName = quest.family.recordID.recordName
            let cached = cache.fetchQuestCompletions(family: familyName)
                .filter { $0.questRecordName == questName }
            if !cached.isEmpty, cache.isCacheFresh(familyRecordName: familyName, type: .questCompletion) {
                return cached.map { $0.toQuestCompletion(zoneID: cloudKit.resolvedZoneID) }
                    .sorted { $0.completedDate > $1.completedDate }
            }
        }

        let questRef = CKRecord.Reference(recordID: quest.id, action: .none)
        let predicate = NSPredicate(format: "quest == %@", questRef)
        let all = try await cloudKit.query(
            QuestCompletion.self,
            predicate: predicate,
            sortDescriptors: [NSSortDescriptor(key: "completedDate", ascending: false)]
        )
        cacheService?.upsertQuestCompletions(all)
        return all
    }

    /// Cache-first read. Background refresh handled by SyncEngine via push notifications.
    func fetchQuestLogs(for profile: Profile) async throws -> [QuestCompletion] {
        if let cache = cacheService {
            let profileName = profile.id.recordName
            let familyName = profile.family.recordID.recordName
            let cached = cache.fetchQuestCompletions(family: familyName)
                .filter { $0.completerRecordName == profileName }
            if !cached.isEmpty, cache.isCacheFresh(familyRecordName: familyName, type: .questCompletion) {
                return cached.map { $0.toQuestCompletion(zoneID: cloudKit.resolvedZoneID) }
                    .sorted { $0.completedDate > $1.completedDate }
            }
        }

        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(format: "completedBy == %@", profileRef)
        let all = try await cloudKit.query(
            QuestCompletion.self,
            predicate: predicate,
            sortDescriptors: [NSSortDescriptor(key: "completedDate", ascending: false)]
        )
        cacheService?.upsertQuestCompletions(all)
        return all
    }

    // MARK: - Batch Fetch

    /// Cache-first read. Background refresh handled by SyncEngine via push notifications.
    func fetchQuestCompletionsForFamily(family: Family) async throws -> [QuestCompletion] {
        if let cache = cacheService {
            let familyName = family.id.recordName
            let cached = cache.fetchQuestCompletions(family: familyName)
            if !cached.isEmpty, cache.isCacheFresh(familyRecordName: familyName, type: .questCompletion) {
                let zoneID = cloudKit.resolvedZoneID
                return cached.map { $0.toQuestCompletion(zoneID: zoneID) }
            }
        }

        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let predicate = NSPredicate(format: "family == %@", familyRef)
        let completions = try await cloudKit.query(
            QuestCompletion.self,
            predicate: predicate,
            sortDescriptors: [NSSortDescriptor(key: "completedDate", ascending: false)]
        )
        cacheService?.upsertQuestCompletions(completions, family: family.id.recordName)
        return completions
    }

    /// Cache-first quest resolution for the reward step of `verify`. Returns
    /// the cached quest when the family's quest cache is fresh
    /// (freshness watermark); falls back to a single CloudKit fetch on a stale or
    /// partial cache.
    private func resolveQuest(for questLog: QuestCompletion) async throws -> Quest {
        let questID = questLog.quest.recordID
        let familyName = questLog.family.recordID.recordName
        if let cache = cacheService,
           cache.isCacheFresh(familyRecordName: familyName, type: .quest),
           let cached = cache.fetchQuests(family: familyName)
           .first(where: { $0.recordName == questID.recordName })
        {
            return cached.toQuest(zoneID: cloudKit.resolvedZoneID)
        }
        return try await cloudKit.fetch(Quest.self, id: questID)
    }

    /// Cache-first hero (completer) resolution for the reward step of `verify`.
    /// CloudKit is only consulted when the family's profile cache is stale or
    /// the profile is absent from it.
    private func resolveHero(for questLog: QuestCompletion) async throws -> Profile {
        let heroID = questLog.completedBy.recordID
        let familyName = questLog.family.recordID.recordName
        if let cache = cacheService,
           cache.isCacheFresh(familyRecordName: familyName, type: .profile),
           let cached = cache.fetchProfile(recordName: heroID.recordName)
        {
            return cached.toProfile(zoneID: cloudKit.resolvedZoneID)
        }
        return try await cloudKit.fetch(Profile.self, id: heroID)
    }

    /// Strictly-local cached logs for a quest, sorted newest-first. Unlike
    /// `fetchQuestLogs(forQuest:useCache:)` this NEVER falls through to a
    /// CloudKit query — it exists for the pre-write path of `markComplete`
    /// where any network round-trip would break the 0ms mutation promise.
    private func cachedQuestLogs(forQuest quest: Quest) -> [QuestCompletion] {
        guard let cache = cacheService else { return [] }
        let questName = quest.id.recordName
        return cache.fetchQuestCompletions(family: quest.family.recordID.recordName)
            .filter { $0.questRecordName == questName }
            .map { $0.toQuestCompletion(zoneID: cloudKit.resolvedZoneID) }
            .sorted { $0.completedDate > $1.completedDate }
    }

    /// Gold credit routes through the shared `GoldCalculation` helper — the
    /// same one `TreasuryService.sumGold` uses — so the reward step and the
    /// wallet never disagree on a partially completed quest. XP routes through
    /// the same targetCount-aware proration (`GoldCalculation.xpCredit`) so
    /// over-completion (stale cache / concurrent devices) can never mint
    /// duplicate XP beyond the quest bounty. The persisted `QuestCompletion`
    /// record remains the credit TreasuryService sums; no parallel wallet
    /// write happens here.
    ///
    /// The XP grant is ANCHORED TO CLOUDKIT RECORDS (security remediation for
    /// finding 2): `QuestCompletion.xpCredited` is the per-record idempotency
    /// marker (each approved completion is rewarded at most once) and
    /// `Quest.xpBanked` is the server-authoritative monotonic per-quest banked
    /// total. Both live on CloudKit records in the family zone — shared across
    /// devices — so a concurrent cross-device completion whose post-save
    /// recount sees only its own log is still capped by the banked total the
    /// winning device wrote. The `xpBanked` write-back is serialized with
    /// CloudKit's change-tag optimistic concurrency (`serverRecordChanged` →
    /// re-fetch → recompute → retry), so two devices racing to bank the same
    /// marginal can never both mint it. This is the CAS serialization the
    /// security audit requires; no UserDefaults ledger exists anywhere.
    @discardableResult
    func applyReward(for quest: Quest, to hero: Profile, completion: QuestCompletion) async throws -> Double {
        // Read existing logs cache-first to compute the approved count for the
        // prorated gold AND the capped XP delta. This read runs POST-save
        // (never on the pre-write critical path). The save just succeeded,
        // so this completion is on the server; a transient read failure must
        // not starve a legitimate completion of its reward, so fall back to
        // treating the completed log as a single approved completion.
        let logs = await (try? fetchQuestLogs(forQuest: quest, useCache: true)) ?? []
        let approvedCount = max(1, logs.filter { $0.verificationStatus != .rejected }.count)

        // Per-record idempotency: this completion's reward step has already
        // settled (a retry, a re-run through another path, or a concurrent
        // duplicate) — grant zero additional XP. The gold credit is derived
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
            Task {
                if let family = try? await cloudKit.fetch(Family.self, id: questFamilyID) {
                    _ = try? await treasuryService.processRealTimeSettlement(profile: hero, family: family)
                }
            }
        }

        return creditedGold
    }

    /// Bounded retries for the change-tag CAS write-back of `Quest.xpBanked`.
    /// Two devices racing to bank XP both start from the same authoritative
    /// total; the first save wins and the loser's save fails with
    /// `serverRecordChanged`, after which it re-fetches the quest, recomputes
    /// the marginal against the updated banked total, and retries — so the
    /// quest's XP bounty can never be minted more than once.
    private static let maxXPBankAttempts = 3

    /// Claims the marginal XP for one approved completion against the
    /// server-authoritative `Quest.xpBanked` cap, using CloudKit's change-tag
    /// optimistic concurrency to serialize cross-device grants.
    ///
    /// 1. Resolve the freshest authoritative quest — the family's quest cache
    ///    when fresh (a completed sync pass propagates `xpBanked`), otherwise a
    ///    single CloudKit fetch. The passed-in `quest` may be stale (another
    ///    device banked since it was read) and is used only as a last-resort
    ///    fallback when the fetch fails.
    /// 2. Compute the marginal grant via `GoldCalculation.marginalXPCredit`
    ///    against the authoritative banked total.
    /// 3. Write `xpBanked = banked + marginal`, preserving every other quest
    ///    field. On `serverRecordChanged` (CloudKit's CAS conflict) re-fetch
    ///    the authoritative quest, recompute against the updated total, and
    ///    retry — bounded, so two devices racing to bank the same marginal can
    ///    never both mint it.
    /// 4. Grant exactly the claimed XP via `xpService.addXP`.
    ///
    /// Returns the XP granted (`0` when the bounty is already fully banked),
    /// or `nil` if the CAS write-back failed to settle (e.g. retries exhausted).
    private func bankXP(for quest: Quest, to hero: Profile, approvedCount: Int, completion _: QuestCompletion) async -> Int? {
        let questRecordName = quest.id.recordName
        let inFlightKey = "xpBank:\(questRecordName)"

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
                try await xpService.addXP(remaining, to: hero)
                await registry?.deregister(inFlightKey)
                return remaining
            } catch let error as CloudKitServiceError where error == .serverRecordChanged {
                // Another device banked first: re-fetch the authoritative quest
                // and recompute the marginal against the updated banked total.
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
    /// Prefers the family's quest cache when fresh; falls back to a single
    /// CloudKit fetch when the cache is stale or partial. The passed-in
    /// `quest` is used only as a last-resort fallback when the fetch fails (a
    /// transient read failure must not starve a legitimate completion of its
    /// reward).
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
    /// retries exhausted without settling), `applyReward` does NOT call this —
    /// `xpCredited` stays `nil` so a future reward-step re-run can retry the
    /// CAS rather than being permanently suppressed by a spurious `0` stamp.
    /// This is what distinguishes "legitimately capped" (stamp `0`) from
    /// "exhausted" (leave `nil`), the distinction the security remediation
    /// requires. The quest-level `xpBanked` cap remains the authoritative
    /// double-mint guard.
    private func stampCompletionCredit(_ completion: QuestCompletion, xpGain: Int) async {
        var updated = completion
        updated.xpCredited = xpGain
        guard let stamped = try? await cloudKit.save(updated) else { return }
        cacheService?.upsertQuestCompletion(stamped)
    }
}
