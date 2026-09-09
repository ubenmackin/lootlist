//
//  QuestCompletionServiceTests.swift
//  LootList
//
//  Created by Ben Mackin on 9/9/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct QuestCompletionServiceTests {
    private struct TestStack {
        let zoneID: CKRecordZone.ID
        let mock: MockCloudKitService
        let cloudKit: any CloudKitServiceProtocol
        let cache: CacheService
        let appState: AppState
        let hero: Profile
        let family: Family
    }

    private func makeStack() throws -> TestStack {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let mock = MockCloudKitService()
        mock.activeFamilyZoneID = zoneID
        mock.activeIsOwner = true
        let cloudKit: any CloudKitServiceProtocol = mock
        let defaults = UserDefaults.ephemeral()
        let cache = try CacheService(inMemory: true, defaults: defaults)
        let appState = AppState.testState(defaults: defaults)
        appState.cacheService = cache
        let family = ExhaustiveCacheFixtures.sharedFamily(zoneID: zoneID)
        let hero = ExhaustiveCacheFixtures.sharedHero(zoneID: zoneID)
        appState.family = family
        appState.familyZoneID = zoneID
        appState.currentProfile = hero
        appState.isZoneOwner = true
        return TestStack(zoneID: zoneID, mock: mock, cloudKit: cloudKit, cache: cache, appState: appState, hero: hero, family: family)
    }

    private func makeCompletionService(
        cloudKit: any CloudKitServiceProtocol,
        cache: CacheService,
        appState: AppState
    ) -> QuestCompletionService {
        let xpService = XPService(cloudKit: cloudKit, cacheService: cache, appState: appState)
        let rewardService = QuestRewardService(
            cloudKit: cloudKit,
            cacheService: cache,
            appState: appState,
            syncCoordinator: NoopSyncEnqueuing(),
            xpService: xpService
        )
        return QuestCompletionService(
            cloudKit: cloudKit,
            cacheService: cache,
            appState: appState,
            syncCoordinator: NoopSyncEnqueuing(),
            xpService: xpService,
            rewardService: rewardService
        )
    }

    @Test
    func `push delivered completion double ingest awards trophy exactly once`() async throws {
        let stack = try makeStack()
        let zoneID = stack.zoneID
        let cloudKit = stack.cloudKit
        let cache = stack.cache
        let appState = stack.appState
        let hero = stack.hero
        let family = stack.family
        let completionService = makeCompletionService(cloudKit: cloudKit, cache: cache, appState: appState)
        let achievementService = AchievementService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let familyRef = ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID)
        let heroRef = CKRecord.Reference(recordID: hero.id, action: .none)
        let weekOf = WeekMath.mondayOfWeek(for: Date())
        let quest = Quest(
            template: CKRecord.Reference(recordID: CKRecord.ID(recordName: "tmpl-push-1", zoneID: zoneID), action: .none),
            assignee: heroRef,
            goldReward: 2500,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: weekOf,
            createdBy: CKRecord.Reference(recordID: family.id, action: .none),
            family: familyRef,
            name: "Push Quest",
            id: CKRecord.ID(recordName: "quest-push-1", zoneID: zoneID)
        )
        let achievement = Achievement(
            id: CKRecord.ID(recordName: "fam1-\(AchievementRequirement.firstQuest.rawValue)", zoneID: zoneID),
            name: "First Steps",
            description: "Complete your first quest",
            iconSystemName: "shoeprints.fill",
            category: .quest,
            requirementType: .firstQuest,
            requirementValue: 1,
            family: familyRef
        )
        let completion = QuestCompletion(
            quest: CKRecord.Reference(recordID: quest.id, action: .none),
            completedBy: heroRef,
            approvalMode: .autoApprove,
            completedDate: weekOf,
            weekOf: weekOf,
            family: familyRef,
            id: CKRecord.ID(recordName: "log-push-1", zoneID: zoneID)
        )
        let reward = RewardEvent(
            profile: heroRef,
            questCompletion: CKRecord.Reference(recordID: completion.id, action: .none),
            xpAmount: 50,
            goldAmount: 2500,
            timestamp: weekOf,
            family: familyRef,
            id: RewardEvent.recordID(completionRecordName: completion.id.recordName, zoneID: zoneID)
        )

        let container = try #require(cache.container)
        let background = BackgroundCacheActor(container: container)
        let resolver = CKSyncConflictResolver(cacheService: cache, appState: appState)
        let handler = CKSyncEngineDelegateHandler(
            backgroundCache: background,
            conflictResolver: resolver,
            cacheService: cache,
            appState: appState
        )
        let pushRecords = [quest.toRecord(), completion.toRecord(), achievement.toRecord(), reward.toRecord()]
        // WHY duplicate push: redelivery must collapse to one cached row per deterministic ID.
        await handler.ingest(records: pushRecords, databaseScope: .private, zoneID: zoneID, notifiesOnCompletion: false)
        await handler.ingest(records: pushRecords, databaseScope: .private, zoneID: zoneID, notifiesOnCompletion: false)

        #expect(cache.fetchQuestCompletions(family: family.id.recordName).count == 1)
        #expect(cache.fetchRewardEvents(family: family.id.recordName).count == 1)
        #expect(completionService.cachedQuestLogs(forQuest: quest).count == 1)

        for type in [CachedRecordType.quest, .questCompletion, .achievement, .profileAchievement, .ledgerEntry, .goal] {
            cache.markCacheFreshForTests(familyRecordName: family.id.recordName, type: type)
        }

        // WHY foreground catchup rides evaluateAll so terminated pushes still award.
        let first = try await achievementService.evaluateAll(for: hero, family: family)
        #expect(first.contains { $0.requirementType == .firstQuest })
        let second = try await achievementService.evaluateAll(for: hero, family: family)
        #expect(second.isEmpty)

        let earned = cache.fetchProfileAchievements(profileRecordName: hero.id.recordName, family: family.id.recordName)
        #expect(earned.count == 1)
        let expectedID = ProfileAchievement.recordID(profileID: hero.id, achievementID: achievement.id, zoneID: zoneID)
        #expect(earned.first?.recordName == expectedID.recordName)
        #expect(cache.fetchRewardEvents(family: family.id.recordName).count == 1)
    }

    @Test
    func `offline empty cache falls back to cached helpers`() async throws {
        let stack = try makeStack()
        let mock = stack.mock
        let cloudKit = stack.cloudKit
        let cache = stack.cache
        let appState = stack.appState
        let hero = stack.hero
        let family = stack.family
        let completionService = makeCompletionService(cloudKit: cloudKit, cache: cache, appState: appState)
        let achievementService = AchievementService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        // WHY offline first: empty cache must render seeded catalog and empty logs without CloudKit.
        #expect(achievementService.cachedOrSeededAchievementCaches(for: family).count == 12)
        let weekOf = WeekMath.mondayOfWeek(for: Date())
        let quest = Quest(
            template: CKRecord.Reference(recordID: CKRecord.ID(recordName: "tmpl-offline", zoneID: hero.id.zoneID), action: .none),
            assignee: CKRecord.Reference(recordID: hero.id, action: .none),
            goldReward: 1000,
            xpReward: 20,
            scheduleType: .weeklyFlexible,
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: weekOf,
            createdBy: CKRecord.Reference(recordID: family.id, action: .none),
            family: CKRecord.Reference(recordID: family.id, action: .none),
            name: "Offline Quest",
            id: CKRecord.ID(recordName: "quest-offline", zoneID: hero.id.zoneID)
        )
        #expect(completionService.cachedQuestLogs(forQuest: quest).isEmpty)

        mock.fetchError = CloudKitServiceError.networkUnavailable
        cache.markCacheFreshForTests(familyRecordName: family.id.recordName, type: .questCompletion)
        let logs = try await completionService.fetchQuestLogs(for: hero)
        #expect(logs.isEmpty)
    }
}
