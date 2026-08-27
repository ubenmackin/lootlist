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
        await scaffold.cache.upsertQuestCompletions([scaffold.completion(status: .pending)])
        // CloudKit truth: a verified log for this quest.
        scaffold.seedMockRecords([scaffold.completion(status: .verified)])

        await #expect(throws: QuestServiceError.alreadyCompleted) {
            try await scaffold.questService.markComplete(quest: scaffold.quest, by: scaffold.hero)
        }
    }

    @Test
    func `markComplete with empty cache proceeds without a pre-write CloudKit check`() async throws {
        let scaffold = try MarkCompleteScaffold()

        scaffold.seedMockRecords([scaffold.completion(status: .verified)])

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

        await scaffold.cache.upsertQuestCompletions([scaffold.completion(status: .rejected)])
        scaffold.seedMockRecords([scaffold.completion(status: .pending)])

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
        let scaffold = try MarkCompleteScaffold()
        await scaffold.cache.upsertQuestCompletions([scaffold.completion(status: .rejected)])

        _ = try await scaffold.questService.markComplete(quest: scaffold.quest, by: scaffold.hero)
        await #expect(throws: QuestServiceError.alreadyCompleted) {
            try await scaffold.questService.markComplete(quest: scaffold.quest, by: scaffold.hero)
        }
    }

    @Test
    func `markComplete performs no CloudKit read before the save`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = NetworkCountingCloudKitService(zoneID: zoneID)
        let scaffold = try MarkCompleteScaffold(cloudKitOverride: cloudKit)

        await scaffold.cache.upsertQuestCompletions([scaffold.completion(status: .rejected)])

        _ = try await scaffold.questService.markComplete(quest: scaffold.quest, by: scaffold.hero)

        #expect(
            cloudKit.readCallCount == 0,
            "markComplete must not query/fetch CloudKit before the save"
        )
    }

    @Test
    func `over-completion beyond targetCount grants zero additional XP`() async throws {
        let scaffold = try MarkCompleteScaffold(
            approvalMode: .autoApprove,
            goldReward: 100.0,
            xpReward: 100,
            targetCount: 2
        )

        var quest = scaffold.quest
        quest.xpBanked = 100
        await scaffold.cache.upsertQuest(quest)

        var hero = scaffold.hero
        hero.xp = 100
        hero.level = 2
        await scaffold.cache.upsertProfile(hero)
        scaffold.appState.currentProfile = hero

        _ = try await scaffold.questService.markComplete(quest: quest, by: hero)

        let cached = scaffold.cache.fetchProfile(recordName: hero.id.recordName, family: "fam1")
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
        await scaffold.cache.upsertProfile(hero)

        _ = try await scaffold.questService.markComplete(quest: scaffold.quest, by: scaffold.hero)

        let cached = scaffold.cache.fetchProfile(recordName: scaffold.hero.id.recordName, family: "fam1")
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

        scaffold.seedMockRecords([
            scaffold.completion(status: .autoApproved, recordName: "log1")
        ])

        var hero = scaffold.hero
        hero.xp = 33
        hero.level = 1
        await scaffold.cache.upsertProfile(hero)
        scaffold.seedMockRecords([hero])

        _ = try await scaffold.questService.markComplete(quest: scaffold.quest, by: hero)

        let cached = scaffold.cache.fetchProfile(recordName: scaffold.hero.id.recordName, family: "fam1")
        #expect(
            cached?.xpTotal == 66,
            "Mid-target completion must grant only the prorated marginal XP"
        )
    }

    @Test
    func `concurrent cross-device completions of a targetCount=1 quest cannot mint more than one XP bounty`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService(zoneID: zoneID)

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
        await deviceA.cache.upsertProfile(hero)
        await deviceB.cache.upsertProfile(hero)
        deviceA.cache.markCacheFresh(familyRecordName: "fam1", type: .questCompletion)
        deviceB.cache.markCacheFresh(familyRecordName: "fam1", type: .questCompletion)

        _ = try await deviceA.questService.markComplete(quest: deviceA.quest, by: hero)
        let cachedA = deviceA.cache.fetchProfile(recordName: hero.id.recordName, family: "fam1")
        #expect(cachedA?.xpTotal == 100)
        var questB = deviceB.quest
        questB.xpBanked = 100
        await deviceB.cache.upsertQuest(questB)
        var heroB = hero
        heroB.xp = 100
        await deviceB.cache.upsertProfile(heroB)
        deviceB.appState.currentProfile = heroB
        _ = try await deviceB.questService.markComplete(quest: questB, by: heroB)

        let cachedB = deviceB.cache.fetchProfile(recordName: hero.id.recordName, family: "fam1")
        #expect(cachedB?.xpTotal == 100)
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
        await scaffold.cache.upsertProfile(hero)
        scaffold.appState.currentProfile = hero

        let log = try await scaffold.questService.markComplete(quest: scaffold.quest, by: hero)

        // First pass banks the full bounty and stamps the per-record marker.
        let cachedLog = try #require(scaffold.cache.fetchQuestCompletions(family: scaffold.familyRef.recordID.recordName).first { $0.recordName == log.id.recordName })
        #expect(
            cachedLog.xpCredited == 100,
            "The reward step must persist the per-record xpCredited marker"
        )

        // Re-run the reward step with the settled completion: xpCredited is
        // already set, so zero additional XP is granted.
        let stampedCompletion = cachedLog.toQuestCompletion(zoneID: scaffold.zoneID)
        let quest = try #require(scaffold.cache.fetchQuests(family: scaffold.familyRef.recordID.recordName).first?.toQuest(zoneID: scaffold.zoneID))
        let reRunGold = try await scaffold.questService.applyReward(
            for: quest,
            to: hero,
            completion: stampedCompletion
        )

        #expect(reRunGold == 100.0)
        let finalHero = try #require(scaffold.cache.fetchProfile(recordName: hero.id.recordName, family: "fam1"))
        #expect(
            finalHero.xpTotal == 100,
            "A completion whose xpCredited is already set must not be re-rewarded"
        )
        let finalQuest = try #require(scaffold.cache.fetchQuests(family: scaffold.familyRef.recordID.recordName).first { $0.recordName == scaffold.quest.id.recordName })
        #expect(finalQuest.xpBanked == 100, "The banked total must not advance on a re-run")
    }

    @Test
    func `quest xpBanked is synced into QuestCache`() async throws {
        let scaffold = try MarkCompleteScaffold(
            approvalMode: .autoApprove,
            goldReward: 100.0,
            xpReward: 100,
            targetCount: 1
        )
        var hero = scaffold.hero
        hero.xp = 0
        hero.level = 1
        await scaffold.cache.upsertProfile(hero)
        scaffold.appState.currentProfile = hero

        _ = try await scaffold.questService.markComplete(quest: scaffold.quest, by: hero)

        let cached = try #require(
            scaffold.cache.fetchQuests(family: "fam1")
                .first { $0.recordName == scaffold.quest.id.recordName }
        )
        #expect(cached.xpBanked == 100)
        #expect(cached.toQuest(zoneID: scaffold.zoneID).xpBanked == 100)
    }

    @Test
    func `quest bank write-back caps the grant when banked XP reaches the reward limit`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID

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
        await deviceA.cache.upsertProfile(hero)
        await deviceB.cache.upsertProfile(hero)
        deviceA.cache.markCacheFresh(familyRecordName: "fam1", type: .questCompletion)
        deviceB.cache.markCacheFresh(familyRecordName: "fam1", type: .questCompletion)

        _ = try await deviceA.questService.markComplete(quest: deviceA.quest, by: hero)

        var questB = deviceB.quest
        questB.xpBanked = 100
        await deviceB.cache.upsertQuest(questB)
        deviceB.cache.markCacheFresh(familyRecordName: "fam1", type: .quest)
        var heroB = hero
        heroB.xp = 100
        await deviceB.cache.upsertProfile(heroB)
        deviceB.appState.currentProfile = heroB
        _ = try await deviceB.questService.markComplete(quest: questB, by: heroB)

        let finalHeroA = try #require(deviceA.cache.fetchProfile(recordName: hero.id.recordName, family: "fam1"))
        #expect(finalHeroA.xpTotal == 100)

        let finalHeroB = try #require(deviceB.cache.fetchProfile(recordName: hero.id.recordName, family: "fam1"))
        #expect(finalHeroB.xpTotal == 100)
    }

    @Test
    func `a legitimately capped completion stamps xpCredited to zero`() async throws {
        let scaffold = try MarkCompleteScaffold(
            approvalMode: .autoApprove,
            goldReward: 100.0,
            xpReward: 100,
            targetCount: 1
        )

        var hero = scaffold.hero
        hero.xp = 0
        hero.level = 1
        await scaffold.cache.upsertProfile(hero)
        scaffold.appState.currentProfile = hero

        var quest = scaffold.quest
        quest.xpBanked = 100
        await scaffold.cache.upsertQuest(quest)

        let log = try await scaffold.questService.markComplete(quest: quest, by: hero)

        let stamped = try #require(scaffold.cache.fetchQuestCompletions(family: scaffold.familyRef.recordID.recordName).first { $0.recordName == log.id.recordName })
        #expect(
            stamped.xpCredited == 0,
            "A legitimately capped completion must stamp xpCredited = 0"
        )
    }

    // MARK: - Parent-Verified Completions

    @Test
    func `parent-verified completion mints XP to the hero and stamps xpCredited`() async throws {
        let scaffold = try MarkCompleteScaffold(
            approvalMode: .parentVerify,
            goldReward: 25.0,
            xpReward: 50,
            targetCount: 1
        )

        var hero = scaffold.hero
        hero.xp = 0
        hero.level = 1
        await scaffold.cache.upsertProfile(hero)
        await scaffold.cache.upsertQuest(scaffold.quest)
        scaffold.seedMockRecords([scaffold.quest, hero])

        let pending = scaffold.completion(status: .pending)
        await scaffold.cache.upsertQuestCompletion(pending)
        for type in [
            CachedRecordType.quest,
            CachedRecordType.profile,
            CachedRecordType.questCompletion
        ] {
            scaffold.cache.markCacheFresh(familyRecordName: "fam1", type: type)
        }

        scaffold.appState.currentProfile = scaffold.parent

        let saved = try await scaffold.questService.verify(questLog: pending, by: scaffold.parent)
        #expect(saved.verificationStatus == .verified)

        let finalHero = try #require(scaffold.cache.fetchProfile(recordName: scaffold.hero.id.recordName, family: "fam1"))
        #expect(
            finalHero.xpTotal == 50,
            "A parent-verified completion must mint the full XP to the credited hero"
        )

        let stamped = try #require(scaffold.cache.fetchQuestCompletions(family: scaffold.familyRef.recordID.recordName).first { $0.recordName == saved.id.recordName })
        #expect(
            stamped.xpCredited == 50,
            "The verified completion must stamp xpCredited once with the minted XP"
        )

        let finalQuest = try #require(scaffold.cache.fetchQuests(family: scaffold.familyRef.recordID.recordName).first { $0.recordName == scaffold.quest.id.recordName })
        #expect(finalQuest.xpBanked == 50, "Quest.xpBanked must hold exactly one XP bounty")
    }

    @Test
    func `applyReward mints nothing when a non-parent stranger acts on the hero`() async throws {
        let scaffold = try MarkCompleteScaffold(
            approvalMode: .parentVerify,
            goldReward: 25.0,
            xpReward: 50,
            targetCount: 1
        )

        var hero = scaffold.hero
        hero.xp = 0
        hero.level = 1
        await scaffold.cache.upsertProfile(hero)
        await scaffold.cache.upsertQuest(scaffold.quest)
        let completion = scaffold.completion(status: .pending)
        await scaffold.cache.upsertQuestCompletion(completion)

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

        do {
            _ = try await scaffold.questService.applyReward(
                for: scaffold.quest,
                to: hero,
                completion: completion
            )
            #expect(Bool(false), "A non-parent stranger must throw unauthorized from applyReward")
        } catch {
            #expect(error as? FamilyServiceError == .unauthorized)
        }

        let finalHero = try #require(scaffold.cache.fetchProfile(recordName: hero.id.recordName, family: "fam1"))
        #expect(finalHero.xpTotal == 0, "A stranger must not mint XP to the hero")
        let finalQuest = try #require(scaffold.cache.fetchQuests(family: scaffold.familyRef.recordID.recordName).first { $0.recordName == scaffold.quest.id.recordName })
        #expect(finalQuest.xpBanked == 0, "A stranger must not bank XP")
        let finalCompletion = try #require(scaffold.cache.fetchQuestCompletions(family: scaffold.familyRef.recordID.recordName).first { $0.recordName == completion.id.recordName })
        #expect(
            finalCompletion.xpCredited == nil,
            "A stranger must not stamp the idempotency marker"
        )
    }

    @Test
    func `createTemplate throws ScopeViolation on foreign family`() async throws {
        let scaffold = try MarkCompleteScaffold()
        scaffold.appState.currentProfile = scaffold.parent
        let foreignFamily = Family(
            name: "Foreign Guild",
            createdBy: scaffold.parent.id,
            id: CKRecord.ID(recordName: "foreign_fam", zoneID: scaffold.zoneID)
        )
        var foreignParent = scaffold.parent
        foreignParent.family = CKRecord.Reference(recordID: foreignFamily.id, action: .none)

        do {
            _ = try await scaffold.questService.createTemplate(
                name: "Foreign Template",
                defaultGold: 10,
                xpReward: 20,
                createdBy: foreignParent,
                family: foreignFamily
            )
            #expect(Bool(false), "createTemplate must throw ScopeViolation on foreign family")
        } catch let error as ScopeViolation {
            #expect(error == ScopeViolation.familyMismatch(active: "fam1", supplied: "foreign_fam"))
        }
    }

    @Test
    func `assignQuest throws ScopeViolation on foreign family`() async throws {
        let scaffold = try MarkCompleteScaffold()
        scaffold.appState.currentProfile = scaffold.parent
        let foreignFamily = Family(
            name: "Foreign Guild",
            createdBy: scaffold.parent.id,
            id: CKRecord.ID(recordName: "foreign_fam", zoneID: scaffold.zoneID)
        )
        let foreignFamilyRef = CKRecord.Reference(recordID: foreignFamily.id, action: .none)
        var foreignParent = scaffold.parent
        foreignParent.family = foreignFamilyRef
        var foreignHero = scaffold.hero
        foreignHero.family = foreignFamilyRef

        let template = QuestTemplate(
            name: "Template",
            description: "",
            defaultGold: 10,
            xpReward: 20,
            scheduleType: .weeklyFlexible,
            specificDays: [],
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            createdBy: CKRecord.Reference(recordID: foreignParent.id, action: .none),
            family: foreignFamilyRef,
            id: CKRecord.ID(recordName: "tmpl1", zoneID: scaffold.zoneID)
        )

        do {
            _ = try await scaffold.questService.assignQuest(
                template: template,
                assignee: foreignHero,
                weekOf: Date(),
                createdBy: foreignParent,
                family: foreignFamily
            )
            #expect(Bool(false), "assignQuest must throw ScopeViolation on foreign family")
        } catch let error as ScopeViolation {
            #expect(error == ScopeViolation.familyMismatch(active: "fam1", supplied: "foreign_fam"))
        }
    }

    @Test
    func `verify on RewardEvent save failure keeps approval and defers only XP credit`() async throws {
        let mockCK = MockCloudKitService()
        let scaffold = try MarkCompleteScaffold(
            approvalMode: .parentVerify,
            cloudKitOverride: mockCK,
            goldReward: 25.0,
            xpReward: 50,
            targetCount: 1
        )

        var hero = scaffold.hero
        hero.xp = 0
        hero.level = 1
        await scaffold.cache.upsertProfile(hero)
        await scaffold.cache.upsertQuest(scaffold.quest)
        mockCK.seedMockRecords([scaffold.quest, hero])

        let pending = scaffold.completion(status: .pending)
        await scaffold.cache.upsertQuestCompletion(pending)
        for type in [
            CachedRecordType.quest,
            CachedRecordType.profile,
            CachedRecordType.questCompletion
        ] {
            scaffold.cache.markCacheFresh(familyRecordName: "fam1", type: type)
        }

        scaffold.appState.currentProfile = scaffold.parent
        mockCK.saveError = CloudKitServiceError.networkUnavailable

        await #expect(throws: Error.self) {
            _ = try await scaffold.questService.verify(questLog: pending, by: scaffold.parent)
        }

        // The approval decision is durable local-first: a failed reward claim
        // must never strand the completion in pending, or the parent's review
        // queue would never clear.
        let cachedAfterFailure = try #require(scaffold.cache.fetchQuestCompletions(family: "fam1").first { $0.recordName == pending.id.recordName })
        #expect(cachedAfterFailure.verificationStatus == VerificationStatus.verified.rawValue, "Failed reward settlement must not discard the parent's approval")
        #expect(cachedAfterFailure.xpCredited == nil, "xpCredited must remain nil until the atomic RewardEvent claim succeeds")

        // Retrying after settlement failed resolves as already-approved rather
        // than re-running settlement and risking a double credit.
        mockCK.saveError = nil
        await #expect(throws: QuestServiceError.self) {
            _ = try await scaffold.questService.verify(questLog: pending, by: scaffold.parent)
        }
        let cachedAfterRetry = try #require(scaffold.cache.fetchQuestCompletions(family: "fam1").first { $0.recordName == pending.id.recordName })
        #expect(cachedAfterRetry.verificationStatus == VerificationStatus.verified.rawValue)
        #expect(cachedAfterRetry.xpCredited == nil)
    }

    @Test
    func `markComplete throws when hero tries to complete another hero's quest`() async throws {
        let scaffold = try MarkCompleteScaffold()
        let otherHeroID = CKRecord.ID(recordName: "hero2", zoneID: scaffold.zoneID)
        let otherHero = Profile(
            displayName: "Other Hero",
            avatarClass: .rogue,
            avatarPresetID: "rogue_01",
            role: .hero,
            iCloudUserID: otherHeroID,
            family: scaffold.familyRef,
            id: otherHeroID
        )
        await scaffold.cache.upsertProfile(otherHero)
        scaffold.appState.currentProfile = otherHero

        await #expect(throws: FamilyServiceError.unauthorized) {
            try await scaffold.questService.markComplete(quest: scaffold.quest, by: otherHero)
        }
    }

    @Test
    func `questService fetch via single-save spy hydrates exactly once`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let mock = MockCloudKitService(zoneID: zoneID)
        let scaffold = try MarkCompleteScaffold(cloudKitOverride: mock, useSingleSaveSpy: true)
        guard let spy = scaffold.syncSpy else {
            Issue.record("Spy not created")
            return
        }
        // Cache quest row is present but not marked fresh, so fetchActiveQuests must query and hydrate once.
        scaffold.cache.invalidateAllFreshness()
        let before = spy.hydrateCallCount
        let quests = try await scaffold.questService.fetchActiveQuests(profile: scaffold.hero, weekOf: scaffold.quest.weekOf)
        #expect(!quests.isEmpty)
        #expect(spy.hydrateCallCount == before + 1, "fetchActiveQuests should hydrate exactly once via single-save batch")
        // Subsequent cache-hit read must not re-hydrate.
        scaffold.cache.markCacheFresh(familyRecordName: "fam1", type: .quest)
        let cached = try await scaffold.questService.fetchActiveQuests(profile: scaffold.hero, weekOf: scaffold.quest.weekOf)
        #expect(!cached.isEmpty)
        #expect(spy.hydrateCallCount == before + 1, "Cache-hit must not trigger additional hydrate")
    }
}
