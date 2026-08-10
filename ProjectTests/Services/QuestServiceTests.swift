//
//  QuestServiceTests.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
@testable import LootList
import Synchronization
import Testing

@MainActor
struct QuestServiceTests {
    @Test
    func `markComplete throws alreadyCompleted when cache stale pending but CK verified`() async throws {
        let scaffold = try MarkCompleteScaffold()

        // Stale cache: a pending log for this quest.
        scaffold.cache.upsertQuestCompletions([scaffold.completion(status: .pending)])
        // CloudKit truth: a verified log for this quest.
        scaffold.cloudKit.seedMockRecords([scaffold.completion(status: .verified)])

        await #expect(throws: QuestServiceError.alreadyCompleted) {
            try await scaffold.questService.markComplete(quest: scaffold.quest, by: scaffold.hero)
        }
    }

    @Test
    func `markComplete with empty cache proceeds without a pre-write CloudKit check`() async throws {
        let scaffold = try MarkCompleteScaffold()

        // CloudKit truth: a verified log for this quest. The cache is empty so
        // the local gate cannot see it — the pre-write path must NOT query
        // CloudKit to reconcile. Reconciliation is best-effort and
        // post-save only, so the local completion proceeds.
        scaffold.cloudKit.seedMockRecords([scaffold.completion(status: .verified)])

        let saved = try await scaffold.questService.markComplete(quest: scaffold.quest, by: scaffold.hero)

        #expect(saved.verificationStatus == .pending)

        let logs = scaffold.cache.fetchQuestCompletions(family: scaffold.familyRef.recordID.recordName)
        #expect(
            logs.contains { $0.questRecordName == scaffold.quest.id.recordName },
            "markComplete must write the completion locally without a pre-write CloudKit gate"
        )
    }

    @Test
    func `markComplete with stale rejected cache proceeds without a pre-write CloudKit check`() async throws {
        let scaffold = try MarkCompleteScaffold()

        // A rejected log in cache does not count toward the target, and the
        // pre-write path must not reconcile against CloudKit — so the
        // completion proceeds and a fresh log is written.
        scaffold.cache.upsertQuestCompletions([scaffold.completion(status: .rejected)])
        scaffold.cloudKit.seedMockRecords([scaffold.completion(status: .pending)])

        _ = try await scaffold.questService.markComplete(quest: scaffold.quest, by: scaffold.hero)

        let logs = scaffold.cache.fetchQuestCompletions(family: scaffold.familyRef.recordID.recordName)
            .filter { $0.questRecordName == scaffold.quest.id.recordName }
        #expect(
            logs.count == 2,
            "Rejected log (not counted) + new completion = 2 logs for the quest"
        )
    }

    @Test
    func `markComplete double tap is gated by the local in-flight guard`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = GatedCloudKitService(zoneID: zoneID)
        let scaffold = try MarkCompleteScaffold(cloudKitOverride: cloudKit)

        // A rejected log keeps the local alreadyCompleted check below the
        // target; the pre-write cache read is strictly local.
        scaffold.cache.upsertQuestCompletions([scaffold.completion(status: .rejected)])

        // First tap: parks inside cloudKit.save while the guard is active.
        // Capture Sendable values only (the scaffold struct itself is not).
        let service = scaffold.questService
        let quest = scaffold.quest
        let hero = scaffold.hero
        let first = Task { try await service.markComplete(quest: quest, by: hero) }
        // Explicitly wait until the first tap enters park inside cloudKit.save.
        await cloudKit.waitForParked(count: 1)

        // Second tap while the first save is in flight: local no-op, no write.
        await #expect(throws: QuestServiceError.alreadyInFlight) {
            try await scaffold.questService.markComplete(quest: scaffold.quest, by: scaffold.hero)
        }

        // Release the first save; it completes normally.
        cloudKit.releaseSaves()
        _ = try await first.value

        // Exactly one new completion was written (rejected seed + one new).
        let logs = scaffold.cache.fetchQuestCompletions(family: scaffold.familyRef.recordID.recordName)
            .filter { $0.questRecordName == scaffold.quest.id.recordName }
        #expect(
            logs.count == 2,
            "First tap wrote one completion; the guarded second tap must not write a duplicate"
        )
    }

    @Test
    func `markComplete performs no CloudKit read before the save`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = GatedCloudKitService(zoneID: zoneID)
        let scaffold = try MarkCompleteScaffold(cloudKitOverride: cloudKit)

        // Seed a rejected log so the cache-first check is below target without
        // any CloudKit read.
        scaffold.cache.upsertQuestCompletions([scaffold.completion(status: .rejected)])

        // Capture Sendable values only (the scaffold struct itself is not).
        let service = scaffold.questService
        let quest = scaffold.quest
        let hero = scaffold.hero
        let first = Task { try await service.markComplete(quest: quest, by: hero) }
        // Explicitly wait until the first tap enters park inside cloudKit.save.
        await cloudKit.waitForParked(count: 1)

        // While the save is in flight, zero CloudKit reads have occurred — the
        // pre-write critical path is fully local.
        #expect(
            cloudKit.readCallCount == 0,
            "markComplete must not query/fetch CloudKit before the save"
        )

        cloudKit.releaseSaves()
        _ = try await first.value
        // The post-save cache read is served from cache once the family's
        // completion cache is stamped fresh.
        scaffold.cache.markCacheFresh(familyRecordName: "fam1", type: .questCompletion)
        let writtenLogs = try await scaffold.questService.fetchQuestLogs(
            forQuest: scaffold.quest,
            useCache: true
        )
        #expect(
            writtenLogs.count >= 1,
            "markComplete must still write the completion"
        )
    }

    @Test
    func `over-completion beyond targetCount grants zero additional XP`() async throws {
        // targetCount=2 quest whose bounty has already been fully earned by
        // two auto-approved completions on the server ("another device"). This
        // device's cache is stale (empty), so the strictly-local guard lets
        // a third completion through; the post-save reward step must cap XP so
        // the third completion mints no additional XP.
        let scaffold = try MarkCompleteScaffold(
            approvalMode: .autoApprove,
            goldReward: 100.0,
            xpReward: 100,
            targetCount: 2
        )

        // No freshness stamp: applyReward's post-save read must fall through
        // to CloudKit (stale cache = other-device completions invisible
        // locally).
        scaffold.cache.invalidateFreshness(familyRecordName: "fam1", type: .questCompletion)
        scaffold.cloudKit.seedMockRecords([
            scaffold.completion(status: .autoApproved, recordName: "log1"),
            scaffold.completion(status: .autoApproved, recordName: "log2")
        ])

        // Hero has already earned the full 100 XP bounty (2 x 50 prorated).
        var hero = scaffold.hero
        hero.xp = 100
        hero.level = 2
        scaffold.cache.upsertProfile(hero)
        scaffold.cloudKit.seedMockRecords([hero])

        _ = try await scaffold.questService.markComplete(quest: scaffold.quest, by: scaffold.hero)

        // Third approval is beyond targetCount → zero additional XP.
        let cached = scaffold.cache.fetchProfile(recordName: scaffold.hero.id.recordName)
        #expect(
            cached?.xpTotal == 100,
            "Over-completion beyond targetCount must not mint duplicate XP"
        )
    }

    @Test
    func `legitimate single completion grants full XP reward unchanged`() async throws {
        let scaffold = try MarkCompleteScaffold(
            approvalMode: .autoApprove,
            goldReward: 10.0,
            xpReward: 50,
            targetCount: 1
        )
        scaffold.cache.invalidateFreshness(familyRecordName: "fam1", type: .questCompletion)

        var hero = scaffold.hero
        hero.xp = 0
        hero.level = 1
        scaffold.cache.upsertProfile(hero)

        _ = try await scaffold.questService.markComplete(quest: scaffold.quest, by: scaffold.hero)

        // A legitimate first completion of a targetCount=1 quest grants the
        // full XP reward — unchanged from pre-remediation behavior.
        let cached = scaffold.cache.fetchProfile(recordName: scaffold.hero.id.recordName)
        #expect(
            cached?.xpTotal == 50,
            "A legitimate completion of a targetCount=1 quest must grant the full XP reward"
        )
    }

    @Test
    func `mid-target completion grants only the prorated marginal XP`() async throws {
        let scaffold = try MarkCompleteScaffold(
            approvalMode: .autoApprove,
            goldReward: 30.0,
            xpReward: 100,
            targetCount: 3
        )
        scaffold.cache.invalidateFreshness(familyRecordName: "fam1", type: .questCompletion)

        // One legitimate auto-approved completion already on the server; the
        // hero earned its prorated 33 XP (100 / 3).
        scaffold.cloudKit.seedMockRecords([
            scaffold.completion(status: .autoApproved, recordName: "log1")
        ])

        var hero = scaffold.hero
        hero.xp = 33
        hero.level = 1
        scaffold.cache.upsertProfile(hero)
        scaffold.cloudKit.seedMockRecords([hero])

        _ = try await scaffold.questService.markComplete(quest: scaffold.quest, by: hero)

        // Second approved completion → cumulative credit 66 (100/3 * 2), so
        // the marginal grant is 66 - 33 = 33 — never the full 100.
        let cached = scaffold.cache.fetchProfile(recordName: scaffold.hero.id.recordName)
        #expect(
            cached?.xpTotal == 66,
            "Mid-target completion must grant only the prorated marginal XP"
        )
    }

    @Test
    func `concurrent cross-device completions of a targetCount=1 quest cannot mint more than one XP bounty`() async throws {
        // Two devices share the family's CloudKit zone but keep SEPARATE local
        // state — no shared UserDefaults ledger exists anymore. The XP credit
        // ledger lives on CloudKit records (`Quest.xpBanked` +
        // `QuestCompletion.xpCredited`), so the SHARED CloudKit mock IS the
        // shared source of truth: device B's reward step must see device A's
        // banked total through the shared quest record even though B's
        // post-save recount — a FRESH cache that serves only the local log,
        // the finding's exact vector — never shows logA.
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = CloudKitService(zoneID: zoneID)

        let deviceA = try MarkCompleteScaffold(
            approvalMode: .autoApprove,
            cloudKitOverride: cloudKit,
            goldReward: 100.0,
            xpReward: 100,
            targetCount: 1
        )
        let deviceB = try MarkCompleteScaffold(
            approvalMode: .autoApprove,
            cloudKitOverride: cloudKit,
            goldReward: 100.0,
            xpReward: 100,
            targetCount: 1
        )

        // Both devices have a synced hero (0 XP) and a fresh completion cache,
        // so each post-save recount serves ONLY that device's own just-saved
        // completion. The shared mock holds the quest record — the ledger.
        // `hero1` is the same record on both devices (see MarkCompleteScaffold),
        // so a single seed covers every device's hero fetch.
        var hero = deviceA.hero
        hero.xp = 0
        hero.level = 1
        cloudKit.seedMockRecords([deviceA.quest, hero])
        deviceA.cache.upsertProfile(hero)
        deviceB.cache.upsertProfile(hero)
        deviceA.cache.markCacheFresh(familyRecordName: "fam1", type: .questCompletion)
        deviceB.cache.markCacheFresh(familyRecordName: "fam1", type: .questCompletion)

        // Device A completes the quest → logA auto-approves and banks 100 XP
        // on the shared quest record.
        let logA = try await deviceA.questService.markComplete(quest: deviceA.quest, by: deviceA.hero)

        // Device B completes the same quest. Its reward step resolves the
        // authoritative quest from the shared mock and sees A's 100 XP banked,
        // so B's marginal is capped to zero — no second bounty minted.
        let logB = try await deviceB.questService.markComplete(quest: deviceB.quest, by: deviceB.hero)

        // Shared CloudKit truth: the hero earned exactly one 100 XP bounty.
        let finalHero = try await cloudKit.fetch(Profile.self, id: deviceB.hero.id)
        #expect(
            finalHero.xp == 100,
            "Two concurrent completions of a targetCount=1 quest must not mint more than 1× XP bounty"
        )

        // The per-quest banked total on the shared record is exactly one bounty.
        let finalQuest = try await cloudKit.fetch(Quest.self, id: deviceA.quest.id)
        #expect(
            finalQuest.xpBanked == 100,
            "Quest.xpBanked must hold exactly one XP bounty"
        )

        // Per-record idempotency markers: logA settled with 100, logB with 0.
        let stampedA = try await cloudKit.fetch(QuestCompletion.self, id: logA.id)
        let stampedB = try await cloudKit.fetch(QuestCompletion.self, id: logB.id)
        #expect(stampedA.xpCredited == 100)
        #expect(stampedB.xpCredited == 0)
    }

    @Test
    func `marginalXPCredit caps each grant at the remaining bounty`() throws {
        // targetCount=1 quest with a 100 XP bounty.
        let scaffold = try MarkCompleteScaffold(
            approvalMode: .autoApprove,
            goldReward: 100.0,
            xpReward: 100,
            targetCount: 1
        )
        let quest = scaffold.quest

        // No credit banked: the first (apparent) approval grants the full bounty.
        #expect(GoldCalculation.marginalXPCredit(for: quest, approvedCount: 1, alreadyCredited: 0) == 100)
        // Bounty fully banked: a concurrent completion whose recount only sees
        // itself (approvedCount 1) is capped to zero.
        #expect(GoldCalculation.marginalXPCredit(for: quest, approvedCount: 1, alreadyCredited: 100) == 0)
        // A recount that sees both completions (approvedCount 2) is also zero.
        #expect(GoldCalculation.marginalXPCredit(for: quest, approvedCount: 2, alreadyCredited: 100) == 0)
    }

    @Test
    func `marginalXPCredit grants only the prorated marginal for mid-target completions`() throws {
        // targetCount=3 quest with a 100 XP bounty.
        let scaffold = try MarkCompleteScaffold(
            approvalMode: .autoApprove,
            goldReward: 30.0,
            xpReward: 100,
            targetCount: 3
        )
        let quest = scaffold.quest

        // First approval: 33 XP (100/3).
        #expect(GoldCalculation.marginalXPCredit(for: quest, approvedCount: 1, alreadyCredited: 0) == 33)
        // Second approval after 33 banked: marginal 33, remaining 33.
        #expect(GoldCalculation.marginalXPCredit(for: quest, approvedCount: 2, alreadyCredited: 33) == 33)
        // Re-run of an already-credited record: remaining is 0 → nothing more.
        #expect(GoldCalculation.marginalXPCredit(for: quest, approvedCount: 2, alreadyCredited: 66) == 0)
    }

    @Test
    func `completion whose xpCredited is already set is not re-rewarded`() async throws {
        let scaffold = try MarkCompleteScaffold(
            approvalMode: .autoApprove,
            goldReward: 100.0,
            xpReward: 100,
            targetCount: 1
        )
        scaffold.cache.invalidateFreshness(familyRecordName: "fam1", type: .questCompletion)

        var hero = scaffold.hero
        hero.xp = 0
        hero.level = 1
        scaffold.cache.upsertProfile(hero)
        scaffold.cloudKit.seedMockRecords([scaffold.quest, hero])

        let log = try await scaffold.questService.markComplete(quest: scaffold.quest, by: scaffold.hero)

        // First pass banks the full bounty and stamps the per-record marker.
        let stamped = try await scaffold.cloudKit.fetch(QuestCompletion.self, id: log.id)
        #expect(
            stamped.xpCredited == 100,
            "The reward step must persist the per-record xpCredited marker"
        )

        // Re-run the reward step with the settled completion: xpCredited is
        // already set, so zero additional XP is granted.
        let quest = try await scaffold.cloudKit.fetch(Quest.self, id: scaffold.quest.id)
        let reRunGold = try await scaffold.questService.applyReward(
            for: quest,
            to: hero,
            completion: stamped
        )

        // Gold credit is still derived independently (count-capped), but XP is
        // untouched.
        #expect(reRunGold == 100.0)
        let finalHero = try await scaffold.cloudKit.fetch(Profile.self, id: hero.id)
        #expect(
            finalHero.xp == 100,
            "A completion whose xpCredited is already set must not be re-rewarded"
        )
        let finalQuest = try await scaffold.cloudKit.fetch(Quest.self, id: scaffold.quest.id)
        #expect(finalQuest.xpBanked == 100, "The banked total must not advance on a re-run")
    }

    @Test
    func `quest xpBanked is stamped on CloudKit and synced into QuestCache`() async throws {
        let scaffold = try MarkCompleteScaffold(
            approvalMode: .autoApprove,
            goldReward: 100.0,
            xpReward: 100,
            targetCount: 1
        )
        scaffold.cache.invalidateFreshness(familyRecordName: "fam1", type: .questCompletion)

        var hero = scaffold.hero
        hero.xp = 0
        hero.level = 1
        scaffold.cache.upsertProfile(hero)
        scaffold.cloudKit.seedMockRecords([scaffold.quest, hero])

        _ = try await scaffold.questService.markComplete(quest: scaffold.quest, by: scaffold.hero)

        // CloudKit: the server-authoritative banked total is stamped on the
        // quest record.
        let quest = try await scaffold.cloudKit.fetch(Quest.self, id: scaffold.quest.id)
        #expect(
            quest.xpBanked == 100,
            "Quest.xpBanked must be stamped on the CloudKit record after rewarding"
        )

        // Local cache: the reward step's post-save upsert propagated xpBanked
        // into the SwiftData cache row, and toQuest round-trips it.
        let cached = try #require(
            scaffold.cache.fetchQuests(family: "fam1")
                .first { $0.recordName == scaffold.quest.id.recordName }
        )
        #expect(cached.xpBanked == 100)
        #expect(cached.toQuest(zoneID: scaffold.zoneID).xpBanked == 100)
    }

    @Test
    func `quest bank write-back retries on serverRecordChanged and caps the grant`() async throws {
        // The shared CloudKit mock rejects the second Quest save with
        // `serverRecordChanged` — the change-tag CAS conflict the production
        // server raises when device A's banked write lands before device B's.
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = OneShotQuestConflictCloudKitService(zoneID: zoneID)

        let deviceA = try MarkCompleteScaffold(
            approvalMode: .autoApprove,
            cloudKitOverride: cloudKit,
            goldReward: 100.0,
            xpReward: 100,
            targetCount: 1
        )
        let deviceB = try MarkCompleteScaffold(
            approvalMode: .autoApprove,
            cloudKitOverride: cloudKit,
            goldReward: 100.0,
            xpReward: 100,
            targetCount: 1
        )

        // Both devices see the same `hero1` record (see MarkCompleteScaffold),
        // so a single seed covers every device's hero fetch.
        var hero = deviceA.hero
        hero.xp = 0
        hero.level = 1
        cloudKit.seedMockRecords([deviceA.quest, hero])
        deviceA.cache.upsertProfile(hero)
        deviceB.cache.upsertProfile(hero)
        deviceA.cache.markCacheFresh(familyRecordName: "fam1", type: .questCompletion)
        deviceB.cache.markCacheFresh(familyRecordName: "fam1", type: .questCompletion)

        // Device A banks the full bounty: quest.xpBanked 0 → 100 (quest save 1).
        _ = try await deviceA.questService.markComplete(quest: deviceA.quest, by: deviceA.hero)

        // Device B's quest cache is FRESH but predates A's bank — a stale
        // xpBanked=0 snapshot, exactly the race window. Its reward step trusts
        // the cache, attempts to bank 100 (quest save 2), and is rejected with
        // serverRecordChanged. The CAS retry re-fetches the authoritative quest,
        // recomputes the marginal against A's 100, and grants zero.
        deviceB.cache.upsertQuest(deviceB.quest)
        deviceB.cache.markCacheFresh(familyRecordName: "fam1", type: .quest)
        _ = try await deviceB.questService.markComplete(quest: deviceB.quest, by: deviceB.hero)

        // Exactly one bounty minted, despite the stale fresh cache.
        let finalHero = try await cloudKit.fetch(Profile.self, id: deviceA.hero.id)
        #expect(
            finalHero.xp == 100,
            "The CAS retry must not mint a second XP bounty"
        )
        let finalQuest = try await cloudKit.fetch(Quest.self, id: deviceA.quest.id)
        #expect(
            finalQuest.xpBanked == 100,
            "The CAS retry must not inflate the banked total"
        )
    }

    // MARK: - Review remediation: capped vs exhausted CAS (Finding 1)

    @Test
    func `a completion that loses the CAS race is not permanently settled - xpCredited stays nil`() async throws {
        // Sustained contention: every `Quest` save is rejected with
        // `serverRecordChanged`, so `bankXP`'s bounded retry loop exhausts
        // without ever settling. The completion must NOT be permanently marked
        // "rewarded zero" — its `xpCredited` stays `nil` so a future reward-step
        // re-run can retry the CAS, rather than being silently suppressed.
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = AlwaysConflictQuestCloudKitService(zoneID: zoneID)

        let scaffold = try MarkCompleteScaffold(
            approvalMode: .autoApprove,
            cloudKitOverride: cloudKit,
            goldReward: 100.0,
            xpReward: 100,
            targetCount: 1
        )

        var hero = scaffold.hero
        hero.xp = 0
        hero.level = 1
        scaffold.cache.upsertProfile(hero)
        cloudKit.seedMockRecords([scaffold.quest, hero])
        scaffold.cache.markCacheFresh(familyRecordName: "fam1", type: .questCompletion)

        // The completion-save itself (a QuestCompletion) succeeds; only the
        // Quest xpBanked write-back is refused, exhausting the CAS retry loop.
        let saved = try await scaffold.questService.markComplete(quest: scaffold.quest, by: hero)

        // xpCredited must remain nil — the completion is still owed XP and is
        // re-grantable; a permanent `0` stamp would silently suppress it.
        let stamped = try await cloudKit.fetch(QuestCompletion.self, id: saved.id)
        #expect(
            stamped.xpCredited == nil,
            "A completion that lost the CAS race must keep xpCredited nil (re-grantable), not be stamped 0"
        )

        // No XP was banked on the quest either — the write-back never settled.
        let finalQuest = try await cloudKit.fetch(Quest.self, id: scaffold.quest.id)
        #expect(
            finalQuest.xpBanked == 0,
            "No XP must be banked when the CAS write-back never settled"
        )

        // And the hero received no XP.
        let finalHero = try await cloudKit.fetch(Profile.self, id: hero.id)
        #expect(
            finalHero.xp == 0,
            "The hero must not receive XP when the CAS write-back never settled"
        )
    }

    @Test
    func `a legitimately capped completion stamps xpCredited to zero`() async throws {
        // The bounty is already fully banked on the server (xpBanked == bounty),
        // so `marginalXPCredit` returns 0 on iteration 1. This is a legitimate
        // cap — the completion owes nothing — and must stamp `xpCredited = 0`
        // so a re-run does not retry the CAS.
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = CloudKitService(zoneID: zoneID)

        let deviceA = try MarkCompleteScaffold(
            approvalMode: .autoApprove,
            cloudKitOverride: cloudKit,
            goldReward: 100.0,
            xpReward: 100,
            targetCount: 1
        )
        let deviceB = try MarkCompleteScaffold(
            approvalMode: .autoApprove,
            cloudKitOverride: cloudKit,
            goldReward: 100.0,
            xpReward: 100,
            targetCount: 1
        )

        var hero = deviceA.hero
        hero.xp = 0
        hero.level = 1
        cloudKit.seedMockRecords([deviceA.quest, hero])
        deviceA.cache.upsertProfile(hero)
        deviceB.cache.upsertProfile(hero)
        deviceA.cache.markCacheFresh(familyRecordName: "fam1", type: .questCompletion)
        deviceB.cache.markCacheFresh(familyRecordName: "fam1", type: .questCompletion)

        // Device A banks the full bounty → xpBanked 0 → 100.
        _ = try await deviceA.questService.markComplete(quest: deviceA.quest, by: deviceA.hero)

        // Device B's reward step resolves the authoritative quest (now 100
        // banked), sees remaining == 0 on iteration 1, and legitimately stamps 0.
        let logB = try await deviceB.questService.markComplete(quest: deviceB.quest, by: deviceB.hero)

        let stampedB = try await cloudKit.fetch(QuestCompletion.self, id: logB.id)
        #expect(
            stampedB.xpCredited == 0,
            "A legitimately capped completion must stamp xpCredited = 0"
        )

        // The banked total stays at one bounty — B's cap did not mint anything.
        let finalQuest = try await cloudKit.fetch(Quest.self, id: deviceA.quest.id)
        #expect(
            finalQuest.xpBanked == 100,
            "A legitimately capped completion must not advance the banked total"
        )
    }

    // MARK: - Review remediation: cache-hit read path issues ZERO CloudKit fetches (Finding 3)

    @Test
    func `fetchActiveQuests cache-hit issues zero CloudKit fetches when cached quests have nil names`() async throws {
        // A fresh cache with legacy quests whose name is nil. The cache-hit read
        // path must serve these without any per-template CloudKit fetch; the
        // displayName fallback gives a usable title until the write-through stamp
        // arrives.
        let scaffold = try MarkCompleteScaffold()
        let zoneID = scaffold.zoneID
        let cloudKit = NetworkCountingCloudKitService(zoneID: zoneID)

        // Seed a template so the displayName fallback can derive a title, but
        // do NOT seed a Quest record — cache will hold the nameless row.
        let template = QuestTemplate(
            name: "Active Template",
            description: "desc",
            defaultGold: 10,
            xpReward: 20,
            scheduleType: .weeklyFlexible,
            specificDays: [],
            targetCount: 1,
            createdBy: CKRecord.Reference(recordID: scaffold.parent.id, action: .none),
            family: scaffold.familyRef,
            id: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID)
        )
        cloudKit.seedMockRecords([template])

        // Build a quest whose name is nil (legacy row) and write it straight into
        // the local cache by hand, bypassing the CloudKit save path.
        var quest = scaffold.quest
        quest.name = nil
        scaffold.cache.upsertQuest(quest)
        scaffold.cache.markCacheFresh(familyRecordName: scaffold.familyRef.recordID.recordName, type: .quest)

        // Reset the CloudKit read counter after the template seed.
        cloudKit.readCallCount = 0

        // Build a QuestService wired to the counting CloudKit double. Do NOT
        // touch CloudKit on the cache-hit branch — the read counter will catch
        // any ad-hoc fetch.
        let service = QuestService(
            cloudKit: cloudKit,
            xpService: XPService(cloudKit: cloudKit)
        )
        service.cacheService = scaffold.cache

        let hero = scaffold.hero
        let weekOf = WeekMath.mondayOfWeek(for: Date())
        let results = try await service.fetchActiveQuests(profile: hero, weekOf: weekOf)

        // The read must be served from cache with the legacy displayName fallback.
        let served = try #require(
            results.first(where: { $0.id.recordName == quest.id.recordName }),
            "The cache-hit path must return the nameless quest"
        )
        #expect(
            served.displayName.contains("tmpl"),
            "A nil-name quest on a cache-hit should use the legacy template-id displayName fallback"
        )
        // Zero CloudKit reads issued on the cache-hit path.
        #expect(
            cloudKit.readCallCount == 0,
            "fetchActiveQuests must issue ZERO CloudKit reads on a fresh-cache hit, even when quests have nil names"
        )
    }

    // MARK: - Review remediation: in-flight registry namespacing (Finding 4)

    @Test
    func `reward step registers quest recordName in-flight during banking`() async throws {
        // bankXP registers questRecordName directly in inFlightRegistry (Finding 10)
        // so BackgroundCacheActor.batchUpsertQuests correctly shields the quest row.
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = CloudKitService(zoneID: zoneID)

        let scaffold = try MarkCompleteScaffold(
            approvalMode: .autoApprove,
            cloudKitOverride: cloudKit,
            goldReward: 100.0,
            xpReward: 100,
            targetCount: 1
        )

        var hero = scaffold.hero
        hero.xp = 0
        hero.level = 1
        scaffold.cache.upsertProfile(hero)
        cloudKit.seedMockRecords([scaffold.quest, hero])
        scaffold.cache.markCacheFresh(familyRecordName: "fam1", type: .questCompletion)

        let registry = scaffold.cache.inFlightRegistry
        let questRecordName = scaffold.quest.id.recordName

        // Baseline: nothing in flight yet.
        #expect(await registry.contains(questRecordName) == false)

        // The reward step runs and banks XP via `bankXP`.
        _ = try await scaffold.questService.markComplete(quest: scaffold.quest, by: hero)

        // After completion, the in-flight key is deregistered.
        #expect(await registry.contains(questRecordName) == false)
        #expect(await registry.activeRecordNames().isEmpty)
    }

    // MARK: - Cache-first family fetch in real-time settlement

    /// Bounded poll for the fire-and-forget settlement Task to land its
    /// allowance period in the cache before the test asserts on it.
    private func waitForAllowancePeriod(_ cache: CacheService, familyName: String) async -> AllowancePeriodCache? {
        for _ in 0 ..< 500 {
            if let period = cache.fetchAllowancePeriods(family: familyName).first {
                return period
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    @Test
    func `real time settlement after markComplete resolves the family from cache`() async throws {
        // A `.realTime` hero + family wired to a shared CloudKit mock in which
        // the Family record is intentionally ABSENT. The settlement tile spawned
        // by `markComplete` must resolve the family from the fresh cache — if it
        // instead fell through to `cloudKit.fetch(Family...)`, that fetch would
        // throw `notFound` and silently abort settlement.
        let zoneID = CKRecordZone.ID(zoneName: "RealtimeZone", ownerName: "RealtimeOwner")
        let cloudKit = MockCloudKitService()
        let cache = try CacheService(inMemory: true)

        let xp = XPService(cloudKit: cloudKit)
        xp.cacheService = cache
        let questService = QuestService(cloudKit: cloudKit, xpService: xp)
        questService.cacheService = cache
        let treasury = TreasuryService(cloudKit: cloudKit)
        treasury.cacheService = cache
        questService.treasuryService = treasury
        // markComplete is a hero self-action — wire the hero as the acting
        // profile so the identity guard passes.
        let appState = AppState()
        questService.appState = appState
        xp.appState = appState
        treasury.appState = appState

        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let parentID = CKRecord.ID(recordName: "parent1", zoneID: zoneID)
        let heroID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        let hero = Profile(
            displayName: "RealTime Hero",
            avatarClass: .mage,
            avatarPresetID: "mage_01",
            role: .hero,
            iCloudUserID: heroID,
            family: familyRef,
            payoutPolicy: .realTime,
            id: heroID
        )
        let family = Family(
            name: "RealTime Guild",
            createdBy: parentID,
            payoutPolicy: .realTime,
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
        let weekOf = WeekMath.mondayOfWeek(for: Date())
        let questID = CKRecord.ID(recordName: "quest1", zoneID: zoneID)
        let quest = Quest(
            template: CKRecord.Reference(recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none),
            assignee: CKRecord.Reference(recordID: heroID, action: .none),
            goldReward: 25.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: weekOf,
            createdBy: CKRecord.Reference(recordID: parentID, action: .none),
            family: familyRef,
            name: "Settle Quest",
            id: questID
        )

        // Seed the local cache (all layers fresh + non-empty) so every read on
        // the reward path — including the settlement's family lookup — is served
        // locally. The Family record is deliberately NOT saved to CloudKit so a
        // cache miss would abort the settlement.
        cache.upsertFamily(family)
        cache.upsertProfile(hero)
        cache.upsertQuest(quest)
        // A rejected pre-existing log keeps the double-submit gate open while
        // still priming the completion cache non-empty.
        var rejectedLog = QuestCompletion(
            quest: CKRecord.Reference(recordID: questID, action: .none),
            completedBy: CKRecord.Reference(recordID: heroID, action: .none),
            approvalMode: .autoApprove,
            weekOf: weekOf,
            family: familyRef,
            id: CKRecord.ID(recordName: "log_seed", zoneID: zoneID)
        )
        rejectedLog.verificationStatus = .rejected
        cache.upsertQuestCompletions([rejectedLog])
        for type in [
            CachedRecordType.family,
            CachedRecordType.profile,
            CachedRecordType.quest,
            CachedRecordType.questCompletion
        ] {
            cache.markCacheFresh(familyRecordName: family.id.recordName, type: type)
        }
        // Seed only the hero into CloudKit; the family must remain absent.
        _ = try await cloudKit.save(hero)
        appState.currentProfile = hero

        let saved = try await questService.markComplete(quest: quest, by: hero)
        #expect(saved.verificationStatus == .autoApproved)

        // The fire-and-forget settlement Task resolves the family from the fresh
        // cache (no CloudKit Family fetch) and lands an allowance period settled
        // against that cache-sourced family. If the Task had hit CloudKit for the
        // absent family, settlement would have aborted and no period would exist.
        let periodCache = await waitForAllowancePeriod(cache, familyName: family.id.recordName)
        let period = try #require(
            periodCache,
            "Settlement must use the cache-sourced family and persist an allowance period"
        )
        #expect(period.totalEarned == 25.0, "Fresh quest gold must be settled onto the period")
        #expect(period.questsCompleted == 1)
    }

    // MARK: - Parent-verified completions mint XP (Finding: applyReward parent guard)

    @Test
    func `parent-verified completion mints XP to the hero and stamps xpCredited`() async throws {
        // A `.parentVerify` quest: the hero marks done → pending (no reward on
        // `markComplete`), then the parent approves via `verify`. Prior to the
        // fix, `applyReward`'s identity guard (`acting.id == hero.id`) failed
        // for the parent acting profile, so `bankXP`/`addXP` were skipped and
        // the hero earned no XP. The guard must authorize the acting parent and
        // mint the full XP to the credited hero.
        let scaffold = try MarkCompleteScaffold(
            approvalMode: .parentVerify,
            goldReward: 25.0,
            xpReward: 50,
            targetCount: 1
        )

        // Seed quest + hero into the shared CloudKit mock and the local cache,
        // and stamp the family caches fresh so verify's post-save reward
        // resolution and the reward-step recount are served deterministically.
        var hero = scaffold.hero
        hero.xp = 0
        hero.level = 1
        scaffold.cache.upsertProfile(hero)
        scaffold.cache.upsertQuest(scaffold.quest)
        scaffold.cloudKit.seedMockRecords([scaffold.quest, hero])

        let pending = scaffold.completion(status: .pending)
        scaffold.cache.upsertQuestCompletion(pending)
        for type in [
            CachedRecordType.quest,
            CachedRecordType.profile,
            CachedRecordType.questCompletion
        ] {
            scaffold.cache.markCacheFresh(familyRecordName: "fam1", type: type)
        }

        // The parent is the authenticated session verifying the hero's pending completion.
        scaffold.appState.currentProfile = scaffold.parent

        let saved = try await scaffold.questService.verify(questLog: pending, by: scaffold.parent)
        #expect(saved.verificationStatus == .verified)

        // The parent-verified completion mints the full XP bounty to the hero.
        let finalHero = try await scaffold.cloudKit.fetch(Profile.self, id: scaffold.hero.id)
        #expect(
            finalHero.xp == 50,
            "A parent-verified completion must mint the full XP to the credited hero"
        )

        // The per-record idempotency marker is stamped exactly once on the verified log.
        let stamped = try await scaffold.cloudKit.fetch(QuestCompletion.self, id: saved.id)
        #expect(
            stamped.xpCredited == 50,
            "The verified completion must stamp xpCredited once with the minted XP"
        )

        // The server-authoritative per-quest banked total holds exactly one bounty.
        let finalQuest = try await scaffold.cloudKit.fetch(Quest.self, id: scaffold.quest.id)
        #expect(finalQuest.xpBanked == 50, "Quest.xpBanked must hold exactly one XP bounty")
    }

    @Test
    func `applyReward mints nothing when a non-parent stranger acts on the hero`() async throws {
        // The authorization relaxation must NOT weaken the rejection of a
        // non-parent, non-self stranger. A hero with no relation to the quest's
        // credited hero who bypasses the guarded `verify` entry and calls
        // `applyReward` directly must still receive zero — no XP, no banked
        // credit, no idempotency stamp.
        let scaffold = try MarkCompleteScaffold(
            approvalMode: .parentVerify,
            goldReward: 25.0,
            xpReward: 50,
            targetCount: 1
        )

        var hero = scaffold.hero
        hero.xp = 0
        hero.level = 1
        scaffold.cache.upsertProfile(hero)
        scaffold.cache.upsertQuest(scaffold.quest)
        let completion = scaffold.completion(status: .pending)
        scaffold.cache.upsertQuestCompletion(completion)
        scaffold.cloudKit.seedMockRecords([scaffold.quest, hero, completion])

        // The authenticated session is a stranger hero (not the credited hero,
        // not a parent).
        let stranger = Profile(
            displayName: "Stranger Hero",
            avatarClass: .mage,
            avatarPresetID: "mage_01",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "stranger", zoneID: scaffold.zoneID),
            family: scaffold.familyRef,
            id: CKRecord.ID(recordName: "stranger1", zoneID: scaffold.zoneID)
        )
        scaffold.appState.currentProfile = stranger

        let gold = try await scaffold.questService.applyReward(
            for: scaffold.quest,
            to: hero,
            completion: completion
        )

        #expect(gold == 0, "A non-parent stranger must earn zero from applyReward")
        let finalHero = try await scaffold.cloudKit.fetch(Profile.self, id: hero.id)
        #expect(finalHero.xp == 0, "A stranger must not mint XP to the hero")
        let finalQuest = try await scaffold.cloudKit.fetch(Quest.self, id: scaffold.quest.id)
        #expect(finalQuest.xpBanked == 0, "A stranger must not bank XP")
        let finalCompletion = try await scaffold.cloudKit.fetch(QuestCompletion.self, id: completion.id)
        #expect(
            finalCompletion.xpCredited == nil,
            "A stranger must not stamp the idempotency marker"
        )
    }
}
