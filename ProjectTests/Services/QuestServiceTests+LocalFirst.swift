//
//  QuestServiceTests+LocalFirst.swift
//  LootList
//
//  Created by Ben Mackin on 8/26/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

extension QuestServiceTests {
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
        await scaffold.cache.upsertQuest(quest)
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
        await scaffold.cache.upsertProfile(hero)
        cloudKit.seedMockRecords([scaffold.quest, hero])
        scaffold.cache.markCacheFresh(familyRecordName: "fam1", type: .questCompletion)

        let resolver = CKSyncConflictResolver(cacheService: scaffold.cache, appState: scaffold.appState)
        let delegate = CKSyncEngineDelegateHandler(conflictResolver: resolver, cacheService: scaffold.cache, appState: scaffold.appState)
        let coordinator = CKSyncEngineCoordinator(cloudKitService: cloudKit, delegateHandler: delegate, appState: scaffold.appState)
        scaffold.questService.syncCoordinator = coordinator
        let log = try await scaffold.questService.markComplete(quest: scaffold.quest, by: hero)
        #expect(log.verificationStatus == .autoApproved)
        let cachedLog = scaffold.cache.fetchQuestCompletion(recordName: log.id.recordName, family: "fam1")
        #expect(cachedLog != nil)
    }

    // MARK: - Cache-first family fetch in real-time settlement

    @Test
    func `real time settlement after markComplete resolves the family from cache`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "RealtimeZone", ownerName: "RealtimeOwner")
        let cloudKit = MockCloudKitService(zoneID: zoneID)
        let isolatedDefaults = UserDefaults.ephemeral()
        let cache = try CacheService(inMemory: true, defaults: isolatedDefaults)

        let xp = XPService(cloudKit: cloudKit)
        xp.cacheService = cache
        let questService = QuestService(cloudKit: cloudKit, xpService: xp)
        questService.cacheService = cache
        let treasury = TreasuryService(cloudKit: cloudKit)
        treasury.cacheService = cache
        questService.treasuryService = treasury
        let appState = AppState(defaults: isolatedDefaults)
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

        await cache.upsertFamily(family)
        await cache.upsertProfile(hero)
        await cache.upsertQuest(quest)
        var rejectedLog = QuestCompletion(
            quest: CKRecord.Reference(recordID: questID, action: .none),
            completedBy: CKRecord.Reference(recordID: heroID, action: .none),
            approvalMode: .autoApprove,
            weekOf: weekOf,
            family: familyRef,
            id: CKRecord.ID(recordName: "log_seed", zoneID: zoneID)
        )
        rejectedLog.verificationStatus = .rejected
        await cache.upsertQuestCompletions([rejectedLog])
        for type in [
            CachedRecordType.family,
            CachedRecordType.profile,
            CachedRecordType.quest,
            CachedRecordType.questCompletion
        ] {
            cache.markCacheFresh(familyRecordName: family.id.recordName, type: type)
        }
        cloudKit.seedMockRecords([hero])
        appState.currentProfile = hero

        let saved = try await questService.markComplete(quest: quest, by: hero)
        #expect(saved.verificationStatus == .autoApproved)

        var foundPeriod: AllowancePeriodCache?
        for _ in 0 ..< 500 {
            if let period = cache.fetchAllowancePeriods(family: family.id.recordName).first, period.totalEarned > 0 {
                foundPeriod = period
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let periodCache = foundPeriod ?? cache.fetchAllowancePeriods(family: family.id.recordName).first
        let period = try #require(
            periodCache,
            "Settlement must use the cache-sourced family and persist an allowance period"
        )
        #expect(period.totalEarned == 25.0, "Fresh quest gold must be settled onto the period")
        #expect(period.questsCompleted == 1)
    }

    // MARK: - Local-First Cache Reads

    @Test
    func `fetchTemplates returns cached templates when cache is not marked fresh`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = NetworkCountingCloudKitService(zoneID: zoneID)
        let defaults = UserDefaults.ephemeral()
        let cache = try CacheService(inMemory: true, defaults: defaults)
        let xpService = XPService(cloudKit: cloudKit)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService)
        questService.cacheService = cache

        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let template = QuestTemplate(
            name: "Cached Chore",
            description: "A description",
            defaultGold: 10.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            specificDays: [],
            targetCount: 1,
            createdBy: CKRecord.Reference(recordID: CKRecord.ID(recordName: "parent1", zoneID: zoneID), action: .none),
            family: familyRef,
            id: CKRecord.ID(recordName: "tmpl_cached", zoneID: zoneID)
        )
        await cache.upsertQuestTemplate(template)

        #expect(cache.isCacheFresh(familyRecordName: "fam1", type: .questTemplate) == false)

        let family = Family(
            name: "Guild",
            createdBy: CKRecord.ID(recordName: "parent1", zoneID: zoneID),
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
        let results = try await questService.fetchTemplates(family: family)
        #expect(results.count == 1)
        #expect(results.first?.name == "Cached Chore")
        #expect(cloudKit.readCallCount == 1)
    }

    @Test
    func `fetchActiveQuests returns cached quests when cache is not marked fresh`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = NetworkCountingCloudKitService(zoneID: zoneID)
        let defaults = UserDefaults.ephemeral()
        let cache = try CacheService(inMemory: true, defaults: defaults)
        let xpService = XPService(cloudKit: cloudKit)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService)
        questService.cacheService = cache

        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let heroID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        let hero = Profile(
            displayName: "Hero",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .hero,
            iCloudUserID: heroID,
            family: familyRef,
            id: heroID
        )

        let monday = WeekMath.startOfWeek(for: Date(), payoutDay: .sunday)
        let templateRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none)
        let cachedQuest = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(recordID: heroID, action: .none),
            goldReward: 25.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: monday,
            createdBy: familyRef,
            family: familyRef,
            name: "Cached Quest",
            id: CKRecord.ID(recordName: "quest-cached", zoneID: zoneID)
        )

        await cache.upsertQuests([cachedQuest])
        #expect(cache.isCacheFresh(familyRecordName: "fam1", type: .quest) == false)

        let activeQuests = try await questService.fetchActiveQuests(profile: hero, weekOf: monday)
        #expect(activeQuests.count == 1)
        #expect(activeQuests.first?.name == "Cached Quest")
        #expect(cloudKit.readCallCount == 1)
    }

    @Test
    func `fetchQuestsForFamilyWeek returns cached quests when cache is not marked fresh`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = NetworkCountingCloudKitService(zoneID: zoneID)
        let defaults = UserDefaults.ephemeral()
        let cache = try CacheService(inMemory: true, defaults: defaults)
        let xpService = XPService(cloudKit: cloudKit)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService)
        questService.cacheService = cache

        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let family = Family(
            name: "Guild",
            createdBy: CKRecord.ID(recordName: "parent1", zoneID: zoneID),
            payoutDay: .sunday,
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )

        let monday = WeekMath.startOfWeek(for: Date(), payoutDay: .sunday)
        let templateRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none)
        let heroID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        let cachedQuest = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(recordID: heroID, action: .none),
            goldReward: 25.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: monday,
            createdBy: familyRef,
            family: familyRef,
            name: "Cached Quest",
            id: CKRecord.ID(recordName: "quest-cached", zoneID: zoneID)
        )

        await cache.upsertQuests([cachedQuest])
        #expect(cache.isCacheFresh(familyRecordName: "fam1", type: .quest) == false)

        let quests = try await questService.fetchQuestsForFamilyWeek(family: family, weekOf: monday)
        #expect(quests.count == 1)
        #expect(quests.first?.name == "Cached Quest")
        #expect(cloudKit.readCallCount == 1)
    }
}
