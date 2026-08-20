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
        let scaffold = try MarkCompleteScaffold()
        scaffold.cache.upsertQuestCompletions([scaffold.completion(status: .rejected)])

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

        scaffold.cache.upsertQuestCompletions([scaffold.completion(status: .rejected)])

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
        scaffold.cache.upsertQuest(quest)

        var hero = scaffold.hero
        hero.xp = 100
        hero.level = 2
        scaffold.cache.upsertProfile(hero)
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
        scaffold.cache.upsertProfile(hero)

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

        scaffold.cloudKit.seedMockRecords([
            scaffold.completion(status: .autoApproved, recordName: "log1")
        ])

        var hero = scaffold.hero
        hero.xp = 33
        hero.level = 1
        scaffold.cache.upsertProfile(hero)
        scaffold.cloudKit.seedMockRecords([hero])

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
        deviceA.cache.upsertProfile(hero)
        deviceB.cache.upsertProfile(hero)
        deviceA.cache.markCacheFresh(familyRecordName: "fam1", type: .questCompletion)
        deviceB.cache.markCacheFresh(familyRecordName: "fam1", type: .questCompletion)

        _ = try await deviceA.questService.markComplete(quest: deviceA.quest, by: hero)
        let cachedA = deviceA.cache.fetchProfile(recordName: hero.id.recordName, family: "fam1")
        #expect(cachedA?.xpTotal == 100)
        var questB = deviceB.quest
        questB.xpBanked = 100
        deviceB.cache.upsertQuest(questB)
        var heroB = hero
        heroB.xp = 100
        deviceB.cache.upsertProfile(heroB)
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
        scaffold.cache.upsertProfile(hero)
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
        scaffold.cache.upsertProfile(hero)
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
        deviceA.cache.upsertProfile(hero)
        deviceB.cache.upsertProfile(hero)
        deviceA.cache.markCacheFresh(familyRecordName: "fam1", type: .questCompletion)
        deviceB.cache.markCacheFresh(familyRecordName: "fam1", type: .questCompletion)

        _ = try await deviceA.questService.markComplete(quest: deviceA.quest, by: hero)

        var questB = deviceB.quest
        questB.xpBanked = 100
        deviceB.cache.upsertQuest(questB)
        deviceB.cache.markCacheFresh(familyRecordName: "fam1", type: .quest)
        var heroB = hero
        heroB.xp = 100
        deviceB.cache.upsertProfile(heroB)
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
        scaffold.cache.upsertProfile(hero)
        scaffold.appState.currentProfile = hero

        var quest = scaffold.quest
        quest.xpBanked = 100
        scaffold.cache.upsertQuest(quest)

        let log = try await scaffold.questService.markComplete(quest: quest, by: hero)

        let stamped = try #require(scaffold.cache.fetchQuestCompletions(family: scaffold.familyRef.recordID.recordName).first { $0.recordName == log.id.recordName })
        #expect(
            stamped.xpCredited == 0,
            "A legitimately capped completion must stamp xpCredited = 0"
        )
    }

    // MARK: - Cache-Hit Read Path

    @Test
    func `fetchActiveQuests cache-hit issues zero CloudKit fetches when cached quests have nil names`() async throws {
        let scaffold = try MarkCompleteScaffold()
        let zoneID = scaffold.zoneID
        let cloudKit = NetworkCountingCloudKitService(zoneID: zoneID)

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

        var quest = scaffold.quest
        quest.name = nil
        scaffold.cache.upsertQuest(quest)
        scaffold.cache.markCacheFresh(familyRecordName: scaffold.familyRef.recordID.recordName, type: .quest)

        cloudKit.readCallCount = 0

        let service = QuestService(
            cloudKit: cloudKit,
            xpService: XPService(cloudKit: cloudKit)
        )
        service.cacheService = scaffold.cache

        let hero = scaffold.hero
        let weekOf = WeekMath.mondayOfWeek(for: Date())
        let results = try await service.fetchActiveQuests(profile: hero, weekOf: weekOf)

        let served = try #require(
            results.first(where: { $0.id.recordName == quest.id.recordName }),
            "The cache-hit path must return the nameless quest"
        )
        #expect(
            served.displayName.contains("tmpl"),
            "A nil-name quest on a cache-hit should use the legacy template-id displayName fallback"
        )
        #expect(
            cloudKit.readCallCount == 0,
            "fetchActiveQuests must issue ZERO CloudKit reads on a fresh-cache hit, even when quests have nil names"
        )
    }

    // MARK: - Sync Coordinator Enqueue

    @Test
    func `markComplete enqueues completion save with sync coordinator`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService(zoneID: zoneID)

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

        let resolver = CKSyncConflictResolver(cacheService: scaffold.cache, appState: scaffold.appState)
        let delegate = CKSyncEngineDelegateHandler(conflictResolver: resolver, cacheService: scaffold.cache, appState: scaffold.appState)
        let coordinator = CKSyncEngineCoordinator(cloudKitService: cloudKit, delegateHandler: delegate, appState: scaffold.appState)
        let privateConfig = CKSyncEngine.Configuration(
            database: cloudKit.container.privateCloudDatabase,
            stateSerialization: nil,
            delegate: delegate
        )
        let sharedConfig = CKSyncEngine.Configuration(
            database: cloudKit.container.sharedCloudDatabase,
            stateSerialization: nil,
            delegate: delegate
        )
        coordinator.privateSyncEngine = CKSyncEngine(privateConfig)
        coordinator.sharedSyncEngine = CKSyncEngine(sharedConfig)
        scaffold.questService.syncCoordinator = coordinator

        let log = try await scaffold.questService.markComplete(quest: scaffold.quest, by: hero)

        #expect(log.verificationStatus == .autoApproved)
        let cachedLog = scaffold.cache.fetchQuestCompletion(recordName: log.id.recordName, family: "fam1")
        #expect(cachedLog != nil)
        #expect(coordinator.pendingUploadCount > 0)
    }

    // MARK: - Cache-first family fetch in real-time settlement

    /// Bounded poll for the fire-and-forget settlement Task to land its
    /// allowance period in the cache before the test asserts on it.
    private func waitForAllowancePeriod(_ cache: CacheService, familyName: String) async -> AllowancePeriodCache? {
        for _ in 0 ..< 500 {
            if let period = cache.fetchAllowancePeriods(family: familyName).first, period.totalEarned > 0 {
                return period
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return cache.fetchAllowancePeriods(family: familyName).first
    }

    @Test
    func `real time settlement after markComplete resolves the family from cache`() async throws {
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

        cache.upsertFamily(family)
        cache.upsertProfile(hero)
        cache.upsertQuest(quest)
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
        _ = try await cloudKit.save(hero)
        appState.currentProfile = hero

        let saved = try await questService.markComplete(quest: quest, by: hero)
        #expect(saved.verificationStatus == .autoApproved)

        let periodCache = await waitForAllowancePeriod(cache, familyName: family.id.recordName)
        let period = try #require(
            periodCache,
            "Settlement must use the cache-sourced family and persist an allowance period"
        )
        #expect(period.totalEarned == 25.0, "Fresh quest gold must be settled onto the period")
        #expect(period.questsCompleted == 1)
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
        scaffold.cache.upsertProfile(hero)
        scaffold.cache.upsertQuest(scaffold.quest)
        let completion = scaffold.completion(status: .pending)
        scaffold.cache.upsertQuestCompletion(completion)

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
    func `verify on RewardEvent save failure leaves completion pending and allows clean retry`() async throws {
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
        scaffold.cache.upsertProfile(hero)
        scaffold.cache.upsertQuest(scaffold.quest)
        mockCK.seedMockRecords([scaffold.quest, hero])

        let pending = scaffold.completion(status: .pending)
        scaffold.cache.upsertQuestCompletion(pending)
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

        let cachedAfterFailure = try #require(scaffold.cache.fetchQuestCompletions(family: "fam1").first { $0.recordName == pending.id.recordName })
        #expect(cachedAfterFailure.verificationStatus == VerificationStatus.pending.rawValue, "Failed verify must leave completion in pending state")
        #expect(cachedAfterFailure.xpCredited == nil, "xpCredited must remain nil on failure")

        mockCK.saveError = nil
        let verified = try await scaffold.questService.verify(questLog: pending, by: scaffold.parent)
        #expect(verified.verificationStatus == .verified)

        let cachedAfterSuccess = try #require(scaffold.cache.fetchQuestCompletions(family: "fam1").first { $0.recordName == pending.id.recordName })
        #expect(cachedAfterSuccess.verificationStatus == VerificationStatus.verified.rawValue)
        #expect(cachedAfterSuccess.xpCredited == 50)
    }
}
