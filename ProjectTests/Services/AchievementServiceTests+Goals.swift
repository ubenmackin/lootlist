//
//  AchievementServiceTests+Goals.swift
//  LootList
//
//  Created by Ben Mackin on 9/9/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
extension AchievementServiceTests {
    @Test
    func `first goal created unlocks at one goal and is idempotent`() async throws {
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

        let firstGoalCreated = Achievement(
            id: CKRecord.ID(recordName: "fam1-\(AchievementRequirement.firstGoalCreated.rawValue)", zoneID: zoneID),
            name: "First Goal Created",
            description: "Create your first savings goal",
            iconSystemName: "target",
            category: .goal,
            requirementType: .firstGoalCreated,
            requirementValue: 1,
            family: ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID)
        )
        await cache.upsertAchievement(firstGoalCreated)
        cache.markCacheFreshForTests(familyRecordName: "fam1", type: .achievement)
        cache.markCacheFreshForTests(familyRecordName: "fam1", type: .profileAchievement)
        cache.markCacheFreshForTests(familyRecordName: "fam1", type: .questCompletion)
        cache.markCacheFreshForTests(familyRecordName: "fam1", type: .quest)
        cache.markCacheFreshForTests(familyRecordName: "fam1", type: .ledgerEntry)
        cache.markCacheFreshForTests(familyRecordName: "fam1", type: .goal)

        // No goals yet — not earned.
        var awarded = try await service.evaluateAll(for: hero, family: family)
        #expect(!awarded.contains { $0.requirementType == .firstGoalCreated })

        // Create one goal
        let goal = makeGoal(zoneID, hero: hero, familyRef: ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID))
        await cache.upsertGoal(goal)
        awarded = try await service.handleGoalCreated(for: hero, family: family)
        #expect(awarded.contains { $0.requirementType == .firstGoalCreated })

        // Idempotent — second handle should not re-award.
        let second = try await service.handleGoalCreated(for: hero, family: family)
        #expect(second.isEmpty)
        let cached = cache.fetchProfileAchievements(profileRecordName: hero.id.recordName, family: family.id.recordName)
        #expect(cached.filter { $0.achievementRecordName == "fam1-\(AchievementRequirement.firstGoalCreated.rawValue)" }.count == 1)
    }

    @Test
    func `goal getter unlocks when a goal is completed and is idempotent`() async throws {
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

        let goalGetter = Achievement(
            id: CKRecord.ID(recordName: "fam1-\(AchievementRequirement.goalGetter.rawValue)", zoneID: zoneID),
            name: "Goal Getter",
            description: "Reach a savings goal",
            iconSystemName: "star.circle.fill",
            category: .goal,
            requirementType: .goalGetter,
            requirementValue: 1,
            family: ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID)
        )
        let firstCreated = Achievement(
            id: CKRecord.ID(recordName: "fam1-\(AchievementRequirement.firstGoalCreated.rawValue)", zoneID: zoneID),
            name: "First Goal Created",
            description: "Create your first savings goal",
            iconSystemName: "target",
            category: .goal,
            requirementType: .firstGoalCreated,
            requirementValue: 1,
            family: ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID)
        )
        await cache.upsertAchievement(goalGetter)
        await cache.upsertAchievement(firstCreated)
        cache.markCacheFreshForTests(familyRecordName: "fam1", type: .achievement)
        cache.markCacheFreshForTests(familyRecordName: "fam1", type: .profileAchievement)
        cache.markCacheFreshForTests(familyRecordName: "fam1", type: .questCompletion)
        cache.markCacheFreshForTests(familyRecordName: "fam1", type: .quest)
        cache.markCacheFreshForTests(familyRecordName: "fam1", type: .ledgerEntry)
        cache.markCacheFreshForTests(familyRecordName: "fam1", type: .goal)

        // Create incomplete goal — should award firstGoalCreated but NOT goalGetter
        let incomplete = makeGoal(zoneID, hero: hero, familyRef: ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID), completed: false)
        await cache.upsertGoal(incomplete)
        var awarded = try await service.evaluateAll(for: hero, family: family)
        #expect(awarded.contains { $0.requirementType == .firstGoalCreated })
        #expect(!awarded.contains { $0.requirementType == .goalGetter })

        // Complete the goal — should now award goalGetter
        var completed = incomplete
        completed.completedAt = Date()
        await cache.upsertGoal(completed)
        awarded = try await service.handleGoalCompleted(for: hero, family: family)
        #expect(awarded.contains { $0.requirementType == .goalGetter })

        // Idempotent second completion handle
        let second = try await service.handleGoalCompleted(for: hero, family: family)
        #expect(second.isEmpty)
    }

    @Test
    func `goal trophies are not awarded without any goals`() async throws {
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

        for req in [AchievementRequirement.firstGoalCreated, AchievementRequirement.goalGetter] {
            let ach = Achievement(
                id: CKRecord.ID(recordName: "fam1-\(req.rawValue)", zoneID: zoneID),
                name: req.rawValue,
                description: "goal",
                iconSystemName: "target",
                category: .goal,
                requirementType: req,
                requirementValue: 1,
                family: ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID)
            )
            await cache.upsertAchievement(ach)
        }
        cache.markCacheFreshForTests(familyRecordName: "fam1", type: .achievement)
        cache.markCacheFreshForTests(familyRecordName: "fam1", type: .profileAchievement)
        cache.markCacheFreshForTests(familyRecordName: "fam1", type: .questCompletion)
        cache.markCacheFreshForTests(familyRecordName: "fam1", type: .quest)
        cache.markCacheFreshForTests(familyRecordName: "fam1", type: .ledgerEntry)
        cache.markCacheFreshForTests(familyRecordName: "fam1", type: .goal)

        let awarded = try await service.evaluateAll(for: hero, family: family)
        #expect(!awarded.contains { $0.requirementType == .firstGoalCreated })
        #expect(!awarded.contains { $0.requirementType == .goalGetter })
    }
}
