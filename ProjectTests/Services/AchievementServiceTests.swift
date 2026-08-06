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
        #expect(AchievementRequirement.questCount50.rawValue == "questCount50")
        #expect(AchievementRequirement.questCount100.rawValue == "questCount100")
        #expect(AchievementRequirement.weekly100.rawValue == "weekly100")
        #expect(AchievementRequirement.streak7.rawValue == "streak7")
        #expect(AchievementRequirement.streak30.rawValue == "streak30")
        #expect(AchievementRequirement.gold100.rawValue == "gold100")
        #expect(AchievementRequirement.gold500.rawValue == "gold500")
        #expect(AchievementRequirement.ledgerCount10.rawValue == "ledgerCount10")
        #expect(AchievementRequirement.ledgerWeeks4.rawValue == "ledgerWeeks4")
        #expect(AchievementRequirement.earlyBird9am.rawValue == "earlyBird9am")
    }

    @Test
    func `achievement category raw values`() {
        #expect(AchievementCategory.quest.rawValue == "quest")
        #expect(AchievementCategory.streak.rawValue == "streak")
        #expect(AchievementCategory.gold.rawValue == "gold")
        #expect(AchievementCategory.special.rawValue == "special")
    }

    @Test
    func `profile stats model initialization`() {
        let stats = ProfileStats(
            questCount: 15,
            bestWeeklyCompletion: 1.0,
            longestStreakDays: 8,
            totalGoldEarned: 120.0,
            ledgerCount: 12,
            ledgerWeeksCount: 5,
            earlyBirdQualified: true
        )

        #expect(stats.questCount == 15)
        #expect(stats.bestWeeklyCompletion == 1.0)
        #expect(stats.longestStreakDays == 8)
        #expect(stats.totalGoldEarned == 120.0)
        #expect(stats.ledgerCount == 12)
        #expect(stats.ledgerWeeksCount == 5)
        #expect(stats.earlyBirdQualified == true)
    }

    // MARK: - Identity guards

    private func makeFamilyRef(_ zoneID: CKRecordZone.ID) -> CKRecord.Reference {
        CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID),
            action: .none
        )
    }

    private func makeHero(_ zoneID: CKRecordZone.ID, recordName: String = "hero1") -> Profile {
        let userID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        return Profile(
            displayName: "Child Hero",
            avatarClass: .mage,
            avatarPresetID: "mage_01",
            role: .hero,
            iCloudUserID: userID,
            family: makeFamilyRef(zoneID),
            id: userID
        )
    }

    private func makeParent(_ zoneID: CKRecordZone.ID, recordName: String = "parent1") -> Profile {
        let userID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        return Profile(
            displayName: "Parent GM",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .guildMaster,
            iCloudUserID: userID,
            family: makeFamilyRef(zoneID),
            id: userID
        )
    }

    private func makeFamily(_ zoneID: CKRecordZone.ID) -> Family {
        Family(
            name: "Test Guild",
            createdBy: CKRecord.ID(recordName: "parent1", zoneID: zoneID),
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
    }

    @Test
    func `award throws unauthorized when actor is not target profile and not parent`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = AchievementService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let actor = makeHero(zoneID, recordName: "hero1")
        let victim = makeHero(zoneID, recordName: "hero2")
        let family = makeFamily(zoneID)
        let achievement = Achievement(
            name: "First Steps",
            description: "Complete your first quest",
            iconSystemName: "shoeprints.fill",
            category: .quest,
            requirementType: .firstQuest,
            requirementValue: 1,
            family: makeFamilyRef(zoneID)
        )
        appState.currentProfile = actor

        do {
            _ = try await service.award(achievement, to: victim, family: family)
            #expect(Bool(false), "Expected award to throw unauthorized")
        } catch {
            #expect(error as? FamilyServiceError == .unauthorized)
        }

        // Cache must remain empty — guard fires before any optimistic write.
        let cached = cache.fetchProfileAchievements(profileRecordName: victim.id.recordName)
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

        let hero = makeHero(zoneID)
        let family = makeFamily(zoneID)
        let achievement = Achievement(
            name: "First Steps",
            description: "Complete your first quest",
            iconSystemName: "shoeprints.fill",
            category: .quest,
            requirementType: .firstQuest,
            requirementValue: 1,
            family: makeFamilyRef(zoneID)
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

        let parent = makeParent(zoneID)
        let hero = makeHero(zoneID)
        let family = makeFamily(zoneID)
        let achievement = Achievement(
            name: "First Steps",
            description: "Complete your first quest",
            iconSystemName: "shoeprints.fill",
            category: .quest,
            requirementType: .firstQuest,
            requirementValue: 1,
            family: makeFamilyRef(zoneID)
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

        let actor = makeHero(zoneID, recordName: "hero1")
        let victim = makeHero(zoneID, recordName: "hero2")
        let family = makeFamily(zoneID)
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

        let hero = makeHero(zoneID)
        let family = makeFamily(zoneID)
        appState.currentProfile = hero

        // Should silently no-op rather than throw or write.
        try await service.seedDefaultAchievements(family: family)

        let cached = cache.fetchAchievements(family: family.id.recordName)
        #expect(cached.isEmpty, "seedDefaultAchievements must not write for a non-parent actor")
    }
}
