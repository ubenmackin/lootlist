//
//  AchievementServiceTests.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct AchievementServiceTests {
    private func makeDependencies() -> (AchievementService, MockCloudKitService) {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        let achievementService = AchievementService(cloudKit: cloudKit)
        return (achievementService, cloudKit)
    }

    @Test
    func `achievement requirement raw values`() {
        #expect(AchievementRequirement.firstQuest.rawValue == "firstQuest")
        #expect(AchievementRequirement.questCount10.rawValue == "questCount10")
        #expect(AchievementRequirement.questCount25.rawValue == "questCount25")
        #expect(AchievementRequirement.questCount50.rawValue == "questCount50")
        #expect(AchievementRequirement.questCount100.rawValue == "questCount100")
        #expect(AchievementRequirement.weekly100.rawValue == "weekly100")
        #expect(AchievementRequirement.streak7.rawValue == "streak7")
        #expect(AchievementRequirement.streak30.rawValue == "streak30")
        #expect(AchievementRequirement.firstGoalCreated.rawValue == "firstGoalCreated")
        #expect(AchievementRequirement.goalGetter.rawValue == "goalGetter")
        #expect(AchievementRequirement.ledgerCount10.rawValue == "ledgerCount10")
        #expect(AchievementRequirement.earlyBird9am.rawValue == "earlyBird9am")
        // Legacy retained for decode.
        #expect(AchievementRequirement.gold100.rawValue == "gold100")
        #expect(AchievementRequirement.gold500.rawValue == "gold500")
        #expect(AchievementRequirement.ledgerWeeks4.rawValue == "ledgerWeeks4")
    }

    @Test
    func `achievement category raw values`() {
        #expect(AchievementCategory.quest.rawValue == "quest")
        #expect(AchievementCategory.streak.rawValue == "streak")
        #expect(AchievementCategory.gold.rawValue == "gold")
        #expect(AchievementCategory.special.rawValue == "special")
        #expect(AchievementCategory.goal.rawValue == "goal")
    }

    @Test
    func `profile stats model initialization`() {
        let stats = ProfileStats(
            questCount: 15,
            bestWeeklyCompletion: 1.0,
            longestStreakDays: 8,
            totalGoldEarned: 12000,
            ledgerCount: 12,
            ledgerWeeksCount: 5,
            earlyBirdQualified: true,
            goalsCreated: 2,
            goalsCompleted: 1
        )

        #expect(stats.questCount == 15)
        #expect(stats.bestWeeklyCompletion == 1.0)
        #expect(stats.longestStreakDays == 8)
        #expect(stats.totalGoldEarned == 12000)
        #expect(stats.ledgerCount == 12)
        #expect(stats.ledgerWeeksCount == 5)
        #expect(stats.earlyBirdQualified == true)
        #expect(stats.goalsCreated == 2)
        #expect(stats.goalsCompleted == 1)
    }

    @Test
    func `award throws unauthorized when actor is not target profile and not parent`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = AchievementService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let actor = ExhaustiveCacheFixtures.sharedHero(zoneID: zoneID, displayName: "Child Hero", iCloudRecordName: "hero1")
        let victim = ExhaustiveCacheFixtures.sharedHero(zoneID: zoneID, displayName: "Child Hero", iCloudRecordName: "hero2", recordName: "hero2")
        let family = ExhaustiveCacheFixtures.sharedFamily(zoneID: zoneID, creatorUserRecordName: "parent1")
        let achievement = Achievement(
            name: "First Steps",
            description: "Complete your first quest",
            iconSystemName: "shoeprints.fill",
            category: .quest,
            requirementType: .firstQuest,
            requirementValue: 1,
            family: ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID)
        )
        appState.currentProfile = actor

        do {
            _ = try await service.award(achievement, to: victim, family: family)
            #expect(Bool(false), "Expected award to throw unauthorized")
        } catch {
            #expect(error as? FamilyServiceError == .unauthorized)
        }

        // Cache must remain empty — guard fires before any optimistic write.
        let cached = cache.fetchProfileAchievements(profileRecordName: victim.id.recordName, family: family.id.recordName)
        #expect(cached.isEmpty, "award must not write a ProfileAchievement when unauthorized")
    }

    @Test
    func `award succeeds when actor is the target profile`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = AchievementService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let hero = ExhaustiveCacheFixtures.sharedHero(zoneID: zoneID, displayName: "Child Hero", iCloudRecordName: "hero1")
        let family = ExhaustiveCacheFixtures.sharedFamily(zoneID: zoneID, creatorUserRecordName: "parent1")
        let achievement = Achievement(
            name: "First Steps",
            description: "Complete your first quest",
            iconSystemName: "shoeprints.fill",
            category: .quest,
            requirementType: .firstQuest,
            requirementValue: 1,
            family: ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID)
        )
        appState.currentProfile = hero

        let saved = try await service.award(achievement, to: hero, family: family)
        #expect(saved.profile.recordID == hero.id)
    }

    @Test
    func `award succeeds when actor is a parent acting on behalf of a hero`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = AchievementService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let parent = ExhaustiveCacheFixtures.sharedParent(zoneID: zoneID, displayName: "Parent GM", iCloudRecordName: "parent1")
        let hero = ExhaustiveCacheFixtures.sharedHero(zoneID: zoneID, displayName: "Child Hero", iCloudRecordName: "hero1")
        let family = ExhaustiveCacheFixtures.sharedFamily(zoneID: zoneID, creatorUserRecordName: "parent1")
        let achievement = Achievement(
            name: "First Steps",
            description: "Complete your first quest",
            iconSystemName: "shoeprints.fill",
            category: .quest,
            requirementType: .firstQuest,
            requirementValue: 1,
            family: ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID)
        )
        appState.currentProfile = parent

        let saved = try await service.award(achievement, to: hero, family: family)
        #expect(saved.profile.recordID == hero.id)
    }

    @Test
    func `evaluateAll returns empty when actor is not target profile and not parent`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = AchievementService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let actor = ExhaustiveCacheFixtures.sharedHero(zoneID: zoneID, displayName: "Child Hero", iCloudRecordName: "hero1")
        let victim = ExhaustiveCacheFixtures.sharedHero(zoneID: zoneID, displayName: "Child Hero", iCloudRecordName: "hero2", recordName: "hero2")
        let family = ExhaustiveCacheFixtures.sharedFamily(zoneID: zoneID, creatorUserRecordName: "parent1")
        appState.currentProfile = actor

        let awarded = try await service.evaluateAll(for: victim, family: family)
        #expect(awarded.isEmpty, "evaluateAll must return empty for unauthorized actor")
    }

    @Test
    func `seedDefaultAchievements is a no-op for non-parent actor`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = AchievementService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let hero = ExhaustiveCacheFixtures.sharedHero(zoneID: zoneID, displayName: "Child Hero", iCloudRecordName: "hero1")
        let family = ExhaustiveCacheFixtures.sharedFamily(zoneID: zoneID, creatorUserRecordName: "parent1")
        appState.currentProfile = hero

        // Should silently no-op rather than throw or write.
        try await service.seedDefaultAchievements(family: family)

        let cached = cache.fetchAchievements(family: family.id.recordName)
        #expect(cached.isEmpty, "seedDefaultAchievements must not write for a non-parent actor")
    }

    @Test
    func `evaluateAll awards weekly100 when all active assigned quests are completed`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = AchievementService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let hero = ExhaustiveCacheFixtures.sharedHero(zoneID: zoneID, displayName: "Child Hero", iCloudRecordName: "hero1")
        let family = ExhaustiveCacheFixtures.sharedFamily(zoneID: zoneID, creatorUserRecordName: "parent1")
        appState.currentProfile = hero
        appState.family = family

        let weekOf = WeekMath.mondayOfWeek(for: Date())

        let questRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "quest1", zoneID: zoneID), action: .none)
        let quest = Quest(
            template: CKRecord.Reference(recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none),
            assignee: CKRecord.Reference(recordID: hero.id, action: .none),
            goldReward: 10,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: weekOf,
            createdBy: CKRecord.Reference(recordID: family.id, action: .none),
            family: ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID),
            name: "Test Quest",
            id: questRef.recordID
        )

        let log = QuestCompletion(
            quest: questRef,
            completedBy: CKRecord.Reference(recordID: hero.id, action: .none),
            approvalMode: .autoApprove,
            completedDate: weekOf,
            weekOf: weekOf,
            family: ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID),
            id: CKRecord.ID(recordName: "log1", zoneID: zoneID)
        )

        let weeklyAchievement = Achievement(
            id: CKRecord.ID(recordName: "fam1-\(AchievementRequirement.weekly100.rawValue)", zoneID: zoneID),
            name: "Week Warrior",
            description: "Complete all quests in a week",
            iconSystemName: "calendar.badge.checkmark",
            category: .special,
            requirementType: .weekly100,
            requirementValue: 1,
            family: ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID)
        )

        await cache.upsertQuest(quest)
        await cache.upsertQuestCompletion(log)
        await cache.upsertAchievement(weeklyAchievement)
        cache.markCacheFreshForTests(familyRecordName: "fam1", type: .quest)
        cache.markCacheFreshForTests(familyRecordName: "fam1", type: .questCompletion)
        cache.markCacheFreshForTests(familyRecordName: "fam1", type: .achievement)
        cache.markCacheFreshForTests(familyRecordName: "fam1", type: .profileAchievement)
        cache.markCacheFreshForTests(familyRecordName: "fam1", type: .ledgerEntry)

        let awarded = try await service.evaluateAll(for: hero, family: family)
        #expect(awarded.contains { $0.requirementType == .weekly100 })
    }

    @Test
    func `evaluateAll does not award weekly100 when active assigned quests are incomplete`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = AchievementService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let hero = ExhaustiveCacheFixtures.sharedHero(zoneID: zoneID, displayName: "Child Hero", iCloudRecordName: "hero1")
        let family = ExhaustiveCacheFixtures.sharedFamily(zoneID: zoneID, creatorUserRecordName: "parent1")
        appState.currentProfile = hero
        appState.family = family

        let weekOf = WeekMath.mondayOfWeek(for: Date())

        let quest1 = Quest(
            template: CKRecord.Reference(recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none),
            assignee: CKRecord.Reference(recordID: hero.id, action: .none),
            goldReward: 10,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: weekOf,
            createdBy: CKRecord.Reference(recordID: family.id, action: .none),
            family: ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID),
            name: "Test Quest 1",
            id: CKRecord.ID(recordName: "quest1", zoneID: zoneID)
        )

        let quest2 = Quest(
            template: CKRecord.Reference(recordID: CKRecord.ID(recordName: "tmpl2", zoneID: zoneID), action: .none),
            assignee: CKRecord.Reference(recordID: hero.id, action: .none),
            goldReward: 10,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: weekOf,
            createdBy: CKRecord.Reference(recordID: family.id, action: .none),
            family: ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID),
            name: "Test Quest 2",
            id: CKRecord.ID(recordName: "quest2", zoneID: zoneID)
        )

        // Only quest1 has a completion log; quest2 is unfinished
        let log = QuestCompletion(
            quest: CKRecord.Reference(recordID: quest1.id, action: .none),
            completedBy: CKRecord.Reference(recordID: hero.id, action: .none),
            approvalMode: .autoApprove,
            completedDate: weekOf,
            weekOf: weekOf,
            family: ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID),
            id: CKRecord.ID(recordName: "log1", zoneID: zoneID)
        )

        let weeklyAchievement = Achievement(
            id: CKRecord.ID(recordName: "fam1-\(AchievementRequirement.weekly100.rawValue)", zoneID: zoneID),
            name: "Week Warrior",
            description: "Complete all quests in a week",
            iconSystemName: "calendar.badge.checkmark",
            category: .special,
            requirementType: .weekly100,
            requirementValue: 1,
            family: ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID)
        )

        await cache.upsertQuest(quest1)
        await cache.upsertQuest(quest2)
        await cache.upsertQuestCompletion(log)
        await cache.upsertAchievement(weeklyAchievement)
        cache.markCacheFreshForTests(familyRecordName: "fam1", type: .quest)
        cache.markCacheFreshForTests(familyRecordName: "fam1", type: .questCompletion)
        cache.markCacheFreshForTests(familyRecordName: "fam1", type: .achievement)
        cache.markCacheFreshForTests(familyRecordName: "fam1", type: .profileAchievement)
        cache.markCacheFreshForTests(familyRecordName: "fam1", type: .ledgerEntry)

        let awarded = try await service.evaluateAll(for: hero, family: family)
        #expect(!awarded.contains { $0.requirementType == .weekly100 }, "1/2 completed should not qualify for weekly100")
    }

    @Test
    func `evaluateAll weekly ratio with stale cache falls back to CloudKit query`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService()
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = AchievementService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        // WHY anchor: creator must equal hero iCloud so resolvedScope stays owner.
        let family = ExhaustiveCacheFixtures.sharedFamily(zoneID: zoneID, creatorUserRecordName: "hero1")
        let hero = ExhaustiveCacheFixtures.sharedHero(zoneID: zoneID, displayName: "Child Hero", iCloudRecordName: "hero1")
        appState.family = family
        appState.currentProfile = hero
        appState.familyZoneID = zoneID
        appState.isZoneOwner = true
        cloudKit.activeFamilyZoneID = zoneID
        cloudKit.activeIsOwner = true

        let weekOf = WeekMath.startOfWeek(for: Date(), payoutDay: .sunday)
        let templateRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none)
        let quest1 = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(recordID: hero.id, action: .none),
            goldReward: 2500,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: weekOf,
            createdBy: CKRecord.Reference(recordID: family.id, action: .none),
            family: ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID),
            name: "Cloud Quest 1",
            id: CKRecord.ID(recordName: "quest1", zoneID: zoneID)
        )
        let quest2 = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(recordID: hero.id, action: .none),
            goldReward: 2500,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: weekOf,
            createdBy: CKRecord.Reference(recordID: family.id, action: .none),
            family: ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID),
            name: "Cloud Quest 2",
            id: CKRecord.ID(recordName: "quest2", zoneID: zoneID)
        )

        // Only quest1 is completed
        let log = QuestCompletion(
            quest: CKRecord.Reference(recordID: quest1.id, action: .none),
            completedBy: CKRecord.Reference(recordID: hero.id, action: .none),
            approvalMode: .autoApprove,
            completedDate: weekOf,
            weekOf: weekOf,
            family: ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID),
            id: CKRecord.ID(recordName: "log1", zoneID: zoneID)
        )

        let weeklyAchievement = Achievement(
            id: CKRecord.ID(recordName: "fam1-\(AchievementRequirement.weekly100.rawValue)", zoneID: zoneID),
            name: "Week Warrior",
            description: "Complete all quests in a week",
            iconSystemName: "calendar.badge.checkmark",
            category: .special,
            requirementType: .weekly100,
            requirementValue: 1,
            family: ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID)
        )

        // Seed CloudKit directly (NOT cache, simulating cache unfresh)
        _ = try await cloudKit.save(quest1, in: zoneID, using: nil)
        _ = try await cloudKit.save(quest2, in: zoneID, using: nil)
        _ = try await cloudKit.save(log, in: zoneID, using: nil)
        _ = try await cloudKit.save(weeklyAchievement, in: zoneID, using: nil)

        // Cache is completely unfresh / empty
        let awarded = try await service.evaluateAll(for: hero, family: family)
        #expect(!awarded.contains { $0.requirementType == .weekly100 }, "Stale cache fallback should accurately read all 2 assigned quests and reject 1/2 completion")
    }

    @Test
    func `multi target quest does not artificially inflate weekly completion ratio`() async throws {
        let (service, cloudKit) = makeDependencies()
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let hero = ExhaustiveCacheFixtures.sharedHero(zoneID: zoneID, displayName: "Child Hero", iCloudRecordName: "hero1")
        let parent = ExhaustiveCacheFixtures.sharedParent(zoneID: zoneID, displayName: "Parent GM", iCloudRecordName: "parent1")
        let family = Family(name: "Test Family", creatorUserRecordName: parent.id.recordName, id: CKRecord.ID(recordName: "fam1", zoneID: zoneID))
        let appState = AppState()
        appState.currentProfile = parent
        appState.family = family
        appState.familyZoneID = zoneID
        appState.isZoneOwner = true
        cloudKit.activeFamilyZoneID = zoneID
        cloudKit.activeIsOwner = true
        service.appState = appState

        let weekOf = WeekMath.startOfWeek(for: Date(), payoutDay: .sunday)
        let templateRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none)

        // Quest 1 has targetCount = 3
        let quest1 = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(recordID: hero.id, action: .none),
            goldReward: 3000,
            xpReward: 60,
            scheduleType: .weeklyFlexible,
            targetCount: 3,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: weekOf,
            createdBy: CKRecord.Reference(recordID: family.id, action: .none),
            family: ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID),
            name: "Feed the Dog (3x)",
            id: CKRecord.ID(recordName: "quest1", zoneID: zoneID)
        )

        // Quest 2 has targetCount = 1
        let quest2 = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(recordID: hero.id, action: .none),
            goldReward: 1000,
            xpReward: 20,
            scheduleType: .weeklyFlexible,
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: weekOf,
            createdBy: CKRecord.Reference(recordID: family.id, action: .none),
            family: ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID),
            name: "Clean Room",
            id: CKRecord.ID(recordName: "quest2", zoneID: zoneID)
        )

        // Hero completed Quest 1 three times (3 logs), Quest 2 untouched (0 logs)
        let log1 = QuestCompletion(
            quest: CKRecord.Reference(recordID: quest1.id, action: .none),
            completedBy: CKRecord.Reference(recordID: hero.id, action: .none),
            approvalMode: .autoApprove,
            completedDate: weekOf,
            weekOf: weekOf,
            family: ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID),
            id: CKRecord.ID(recordName: "log1", zoneID: zoneID)
        )
        let log2 = QuestCompletion(
            quest: CKRecord.Reference(recordID: quest1.id, action: .none),
            completedBy: CKRecord.Reference(recordID: hero.id, action: .none),
            approvalMode: .autoApprove,
            completedDate: weekOf,
            weekOf: weekOf,
            family: ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID),
            id: CKRecord.ID(recordName: "log2", zoneID: zoneID)
        )
        let log3 = QuestCompletion(
            quest: CKRecord.Reference(recordID: quest1.id, action: .none),
            completedBy: CKRecord.Reference(recordID: hero.id, action: .none),
            approvalMode: .autoApprove,
            completedDate: weekOf,
            weekOf: weekOf,
            family: ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID),
            id: CKRecord.ID(recordName: "log3", zoneID: zoneID)
        )

        let weeklyAchievement = Achievement(
            id: CKRecord.ID(recordName: "fam1-\(AchievementRequirement.weekly100.rawValue)", zoneID: zoneID),
            name: "Week Warrior",
            description: "Complete all quests in a week",
            iconSystemName: "calendar.badge.checkmark",
            category: .special,
            requirementType: .weekly100,
            requirementValue: 1,
            family: ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID)
        )

        _ = try await cloudKit.save(quest1, in: zoneID, using: nil)
        _ = try await cloudKit.save(quest2, in: zoneID, using: nil)
        _ = try await cloudKit.save(log1, in: zoneID, using: nil)
        _ = try await cloudKit.save(log2, in: zoneID, using: nil)
        _ = try await cloudKit.save(log3, in: zoneID, using: nil)
        _ = try await cloudKit.save(weeklyAchievement, in: zoneID, using: nil)

        let awarded = try await service.evaluateAll(for: hero, family: family)
        #expect(!awarded.contains { $0.requirementType == .weekly100 }, "1 out of 2 quests completed should yield 50% weekly ratio, not 100%, despite 3 logs on Quest 1")
    }

    @Test
    func `quest count thresholds cross at 10 25 50 100`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = AchievementService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let hero = ExhaustiveCacheFixtures.sharedHero(zoneID: zoneID, displayName: "Child Hero", iCloudRecordName: "hero1")
        let family = ExhaustiveCacheFixtures.sharedFamily(zoneID: zoneID, creatorUserRecordName: "parent1")
        appState.currentProfile = hero
        appState.family = family
        let weekOf = WeekMath.mondayOfWeek(for: Date())
        seedQuestCountAchievements(in: cache, zoneID: zoneID, familyRef: ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID))

        // 9 completions — should only award firstQuest, not 10
        seedCompletions(count: 9, hero: hero, zoneID: zoneID, familyRef: ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID), cache: cache, weekOf: weekOf)
        var awarded = try await service.evaluateAll(for: hero, family: family)
        #expect(awarded.contains { $0.requirementType == .firstQuest })
        #expect(!awarded.contains { $0.requirementType == .questCount10 })

        // Add one more to reach 10 — should now award questCount10 (idempotent check below)
        seedCompletions(count: 1, hero: hero, zoneID: zoneID, familyRef: ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID), cache: cache, weekOf: weekOf)
        awarded = try await service.evaluateAll(for: hero, family: family)
        #expect(awarded.contains { $0.requirementType == .questCount10 })

        // Push to 25
        seedCompletions(count: 15, hero: hero, zoneID: zoneID, familyRef: ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID), cache: cache, weekOf: weekOf)
        awarded = try await service.evaluateAll(for: hero, family: family)
        #expect(awarded.contains { $0.requirementType == .questCount25 })

        // Push to 50
        seedCompletions(count: 25, hero: hero, zoneID: zoneID, familyRef: ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID), cache: cache, weekOf: weekOf)
        awarded = try await service.evaluateAll(for: hero, family: family)
        #expect(awarded.contains { $0.requirementType == .questCount50 })

        // Push to 100
        seedCompletions(count: 50, hero: hero, zoneID: zoneID, familyRef: ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID), cache: cache, weekOf: weekOf)
        awarded = try await service.evaluateAll(for: hero, family: family)
        #expect(awarded.contains { $0.requirementType == .questCount100 })
    }

    @Test
    func `quest count unlock is idempotent`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = AchievementService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let hero = ExhaustiveCacheFixtures.sharedHero(zoneID: zoneID, displayName: "Child Hero", iCloudRecordName: "hero1")
        let family = ExhaustiveCacheFixtures.sharedFamily(zoneID: zoneID, creatorUserRecordName: "parent1")
        appState.currentProfile = hero
        appState.family = family
        let weekOf = WeekMath.mondayOfWeek(for: Date())
        seedQuestCountAchievements(in: cache, zoneID: zoneID, familyRef: ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID))
        seedCompletions(count: 10, hero: hero, zoneID: zoneID, familyRef: ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID), cache: cache, weekOf: weekOf)

        let first = try await service.evaluateAll(for: hero, family: family)
        #expect(first.contains { $0.requirementType == .questCount10 })
        let beforeCount = cache.fetchProfileAchievements(profileRecordName: hero.id.recordName, family: family.id.recordName).count

        // Second evaluation without new completions must award nothing.
        let second = try await service.evaluateAll(for: hero, family: family)
        #expect(second.isEmpty, "Second evaluateAll must be idempotent — already earned trophies are not re-awarded")
        let afterCount = cache.fetchProfileAchievements(profileRecordName: hero.id.recordName, family: family.id.recordName).count
        #expect(beforeCount == afterCount, "Deterministic ProfileAchievement IDs must prevent duplicate rows on re-evaluate")

        // Third evaluation also empty — verify stable idempotency.
        let third = try await service.evaluateAll(for: hero, family: family)
        #expect(third.isEmpty)
    }

    @Test
    func `seeded trophy catalog matches the V1 spec and omits legacy criteria`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let appState = AppState.testState()
        let service = AchievementService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let parent = ExhaustiveCacheFixtures.sharedParent(zoneID: zoneID, displayName: "Parent GM", iCloudRecordName: "parent1")
        let family = ExhaustiveCacheFixtures.sharedFamily(zoneID: zoneID, creatorUserRecordName: "parent1")
        appState.currentProfile = parent

        try await service.seedDefaultAchievements(family: family)

        let seeded = cache.fetchAchievements(family: family.id.recordName)
        let v1RequirementTypes: Set<String> = [
            AchievementRequirement.firstQuest.rawValue,
            AchievementRequirement.questCount10.rawValue,
            AchievementRequirement.questCount25.rawValue,
            AchievementRequirement.questCount50.rawValue,
            AchievementRequirement.questCount100.rawValue,
            AchievementRequirement.weekly100.rawValue,
            AchievementRequirement.streak7.rawValue,
            AchievementRequirement.streak30.rawValue,
            AchievementRequirement.firstGoalCreated.rawValue,
            AchievementRequirement.goalGetter.rawValue,
            AchievementRequirement.ledgerCount10.rawValue,
            AchievementRequirement.earlyBird9am.rawValue
        ]
        #expect(seeded.count == 12, "V1 trophy spec has exactly 12 trophies")
        #expect(Set(seeded.map(\.requirementType)) == v1RequirementTypes)

        // Legacy Level/XP/Gem-era criteria must never be seeded again.
        for legacy in [AchievementRequirement.gold100, .gold500, .ledgerWeeks4] {
            #expect(!seeded.contains { $0.requirementType == legacy.rawValue }, "Legacy \(legacy.rawValue) must not be seeded in the V1 catalog")
        }
    }

    @Test
    func `quest count tiers are completion counts not xp or gem thresholds`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let appState = AppState.testState()
        let service = AchievementService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let parent = ExhaustiveCacheFixtures.sharedParent(zoneID: zoneID, displayName: "Parent GM", iCloudRecordName: "parent1")
        let family = ExhaustiveCacheFixtures.sharedFamily(zoneID: zoneID, creatorUserRecordName: "parent1")
        appState.currentProfile = parent

        try await service.seedDefaultAchievements(family: family)

        let seeded = cache.fetchAchievements(family: family.id.recordName)
        let tierValues: [String: Int] = [
            AchievementRequirement.firstQuest.rawValue: 1,
            AchievementRequirement.questCount10.rawValue: 10,
            AchievementRequirement.questCount25.rawValue: 25,
            AchievementRequirement.questCount50.rawValue: 50,
            AchievementRequirement.questCount100.rawValue: 100
        ]
        for (rawValue, expectedValue) in tierValues {
            let tier = seeded.first { $0.requirementType == rawValue }
            #expect(tier != nil, "Quest-count tier \(rawValue) must be part of the seeded catalog")
            #expect(tier?.categoryEnum == .quest)
            #expect(tier?.requirementValue == expectedValue, "Tier \(rawValue) must key on a completion count of \(expectedValue)")
        }
    }

    @Test
    func `replayed quest completion events do not duplicate profile achievements`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let appState = AppState.testState()
        let service = AchievementService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let hero = ExhaustiveCacheFixtures.sharedHero(zoneID: zoneID, displayName: "Child Hero", iCloudRecordName: "hero1")
        let family = ExhaustiveCacheFixtures.sharedFamily(zoneID: zoneID, creatorUserRecordName: "parent1")
        appState.currentProfile = hero
        appState.family = family
        let weekOf = WeekMath.mondayOfWeek(for: Date())
        seedQuestCountAchievements(in: cache, zoneID: zoneID, familyRef: ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID))
        seedCompletions(count: 10, hero: hero, zoneID: zoneID, familyRef: ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID), cache: cache, weekOf: weekOf)

        let first = try await service.evaluateAll(for: hero, family: family)
        #expect(first.contains { $0.requirementType == .firstQuest })
        #expect(first.contains { $0.requirementType == .questCount10 })

        // WHY deterministic IDs must collapse replayed awards into existing rows.
        _ = try await service.handleQuestCompleted(for: hero, family: family)
        let thirdReplay = try await service.handleQuestCompleted(for: hero, family: family)
        #expect(thirdReplay.isEmpty, "Replayed completion events must not re-award earned trophies")

        let cachedRows = cache.fetchProfileAchievements(profileRecordName: hero.id.recordName, family: family.id.recordName)
        #expect(cachedRows.count == first.count, "One ProfileAchievement row per earned trophy — no duplicates from event replay")

        let firstQuestRow = cachedRows.first { $0.recordName == ProfileAchievement.recordID(
            profileID: hero.id,
            achievementID: CKRecord.ID(recordName: "fam1-\(AchievementRequirement.firstQuest.rawValue)", zoneID: zoneID),
            zoneID: zoneID
        ).recordName }
        #expect(firstQuestRow != nil, "firstQuest row must use the deterministic profile+achievement record ID")
    }

    @Test
    func `push delivered completion ingested twice awards trophy exactly once`() async throws {
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
        let service = AchievementService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        // WHY offline first: empty cache must still render the seeded catalog without CloudKit.
        let fallback = service.cachedOrSeededAchievementCaches(for: family)
        #expect(fallback.count == 12)
        #expect(cache.fetchAchievements(family: family.id.recordName).isEmpty)

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
        // WHY duplicate push: redelivered silent pushes must collapse to one row.
        await handler.ingest(records: pushRecords, databaseScope: .private, zoneID: zoneID, notifiesOnCompletion: false)
        await handler.ingest(records: pushRecords, databaseScope: .private, zoneID: zoneID, notifiesOnCompletion: false)
        #expect(cache.fetchQuestCompletions(family: family.id.recordName).count == 1)
        #expect(cache.fetchRewardEvents(family: family.id.recordName).count == 1)
        #expect(cache.fetchAchievements(family: family.id.recordName).count == 1)

        for type in [CachedRecordType.quest, .questCompletion, .achievement, .profileAchievement, .ledgerEntry, .goal] {
            cache.markCacheFreshForTests(familyRecordName: family.id.recordName, type: type)
        }

        // WHY foreground catchup rides evaluateAll so terminated pushes still award.
        let first = try await service.evaluateAll(for: hero, family: family)
        #expect(first.contains { $0.requirementType == .firstQuest })
        let second = try await service.evaluateAll(for: hero, family: family)
        #expect(second.isEmpty)

        let earned = cache.fetchProfileAchievements(profileRecordName: hero.id.recordName, family: family.id.recordName)
        #expect(earned.count == 1)
        let expectedID = ProfileAchievement.recordID(profileID: hero.id, achievementID: achievement.id, zoneID: zoneID)
        #expect(earned.first?.recordName == expectedID.recordName)
        #expect(cache.fetchRewardEvents(family: family.id.recordName).count == 1)
    }
}
