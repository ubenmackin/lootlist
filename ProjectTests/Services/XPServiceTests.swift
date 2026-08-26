//
//  XPServiceTests.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct XPServiceTests {
    @Test
    func `cumulative XP calculations for levels`() {
        #expect(XPService.cumulativeXPForLevel(1) == 0)
        #expect(XPService.cumulativeXPForLevel(2) == 100)
        #expect(XPService.cumulativeXPForLevel(3) == 300)
        #expect(XPService.cumulativeXPForLevel(4) == 600)
        #expect(XPService.cumulativeXPForLevel(5) == 1000)
    }

    @Test
    func `level determination for given XP amounts`() {
        #expect(XPService.level(forXP: 0) == 1)
        #expect(XPService.level(forXP: 50) == 1)
        #expect(XPService.level(forXP: 100) == 2)
        #expect(XPService.level(forXP: 250) == 2)
        #expect(XPService.level(forXP: 300) == 3)
        #expect(XPService.level(forXP: 1000) == 5)
    }

    @Test
    func `level progress calculations`() {
        let dummyZone = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let service = XPService(cloudKit: MockCloudKitService())

        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam123", zoneID: dummyZone), action: .none)
        let userID = CKRecord.ID(recordName: "u123", zoneID: dummyZone)

        var profile = Profile(
            displayName: "Test Hero",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .hero,
            iCloudUserID: userID,
            family: familyRef,
            id: CKRecord.ID(recordName: "hero1", zoneID: dummyZone)
        )
        profile.xp = 150
        profile.level = 2

        let progress = service.levelProgress(profile: profile)
        #expect(progress.currentLevel == 2)
        #expect(progress.xpIntoCurrentLevel == 50)
        #expect(progress.xpForNextLevel == 200)
        #expect(progress.progress == 0.25)
    }

    @Test
    func `rPG Title mapping for level bounds`() {
        #expect(XPService.title(forLevel: 1) == "Novice")
        #expect(XPService.title(forLevel: 2) == "Apprentice")
        #expect(XPService.title(forLevel: 3) == "Adept")
        #expect(XPService.title(forLevel: 4) == "Veteran")
        #expect(XPService.title(forLevel: 5) == "Champion")
        #expect(XPService.title(forLevel: 6) == "Heroic")
        #expect(XPService.title(forLevel: 7) == "Legendary")
        #expect(XPService.title(forLevel: 8) == "Mythic")
        #expect(XPService.title(forLevel: 9) == "Heroic")
        #expect(XPService.title(forLevel: 13) == "Heroic II")
    }

    @Test
    func `unlocked accessories cadence`() {
        let dummyZone = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let service = XPService(cloudKit: MockCloudKitService())
        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam123", zoneID: dummyZone), action: .none)
        let userID = CKRecord.ID(recordName: "u123", zoneID: dummyZone)

        var level3Hero = Profile(
            displayName: "Level 3",
            avatarClass: .mage,
            avatarPresetID: "mage_01",
            role: .hero,
            iCloudUserID: userID,
            family: familyRef
        )
        level3Hero.xp = 300
        level3Hero.level = 3

        #expect(service.unlockedAccessories(profile: level3Hero).isEmpty)

        var level5Hero = Profile(
            displayName: "Level 5",
            avatarClass: .mage,
            avatarPresetID: "mage_01",
            role: .hero,
            iCloudUserID: userID,
            family: familyRef
        )
        level5Hero.xp = 1000
        level5Hero.level = 5

        #expect(service.unlockedAccessories(profile: level5Hero) == ["accessory.level.5"])

        var level10Hero = Profile(
            displayName: "Level 10",
            avatarClass: .mage,
            avatarPresetID: "mage_01",
            role: .hero,
            iCloudUserID: userID,
            family: familyRef
        )
        level10Hero.xp = 4500
        level10Hero.level = 10

        #expect(service.unlockedAccessories(profile: level10Hero) == ["accessory.level.5", "accessory.level.10"])
    }

    // MARK: - addXP snapshot-rollback

    private enum MockError: Error, Equatable {
        case saveFailed
    }

    @MainActor
    private final class FailingCloudKitService: MockCloudKitService {
        override func save<T: CloudKitRecord>(_: T,
                                              in _: CKRecordZone.ID?,
                                              using _: CKDatabase?) async throws -> T
        {
            throw MockError.saveFailed
        }

        override func fetch<T: CloudKitRecord>(_: T.Type,
                                               id _: CKRecord.ID,
                                               using _: CKDatabase?) async throws -> T
        {
            throw MockError.saveFailed
        }
    }

    private func makeHero(zoneID: CKRecordZone.ID, xp: Int, level: Int) -> Profile {
        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let userID = CKRecord.ID(recordName: "u1", zoneID: zoneID)
        var profile = Profile(
            displayName: "Test Hero",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .hero,
            iCloudUserID: userID,
            family: familyRef,
            id: CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        )
        profile.xp = xp
        profile.level = level
        return profile
    }

    @Test
    func `addXP on save success persists saved profile in cache`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = XPService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let hero = makeHero(zoneID: zoneID, xp: 100, level: 1)
        await cache.upsertProfile(hero)
        appState.currentProfile = hero

        let saved = try await service.addXP(50, to: hero)

        // (a) success: cache holds the saved (inflated) profile.
        #expect(saved.xp == 150)
        #expect(saved.level == 2)
        let cached = cache.fetchProfile(recordName: hero.id.recordName, family: hero.family.recordID.recordName)
        #expect(cached != nil)
        #expect(cached?.xpTotal == 150)
        #expect(cached?.level == 2)
    }

    @Test
    func `addXP preserves fresher currentProfile fields instead of replacing them with stale cached values`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = XPService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        // The cache holds the pre-sync profile (knight_01 avatar, perQuest payout).
        let cachedHero = makeHero(zoneID: zoneID, xp: 100, level: 1)
        await cache.upsertProfile(cachedHero)

        // currentProfile carries fresher in-memory UI state (avatar + payout
        // policy changed on another device) that the local cache has not synced.
        var fresher = cachedHero
        fresher.avatarPresetID = "mage_01"
        fresher.payoutPolicy = .realTime
        appState.currentProfile = fresher

        // Grant XP using the stale cache-derived profile.
        let saved = try await service.addXP(50, to: cachedHero)

        // The XP/level deltas land on currentProfile…
        #expect(saved.xp == 150)
        let current = try #require(appState.currentProfile)
        #expect(current.xp == 150)
        #expect(current.level == 2)

        // …but the fresher fields survive the grant untouched rather than being
        // clobbered by the stale cache-derived profile that was granted XP.
        #expect(current.avatarPresetID == "mage_01")
        #expect(current.payoutPolicy == .realTime)
    }

    @Test
    func `addXP writes immediately to local cache`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = FailingCloudKitService()
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = XPService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let hero = makeHero(zoneID: zoneID, xp: 100, level: 1)
        await cache.upsertProfile(hero)
        appState.currentProfile = hero

        let returned = try await service.addXP(50, to: hero)
        #expect(returned.xp == 150)
        #expect(returned.level == 2)

        let cached = cache.fetchProfile(recordName: hero.id.recordName, family: hero.family.recordID.recordName)
        #expect(cached?.xpTotal == 150)
        #expect(cached?.level == 2)
    }

    // MARK: - Identity guard

    @Test
    func `addXP throws unauthorized when acting profile differs from target`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = XPService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let familyRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID),
            action: .none
        )
        let actor = Profile(
            displayName: "Actor",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "u1", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        )
        let victim = Profile(
            displayName: "Victim",
            avatarClass: .mage,
            avatarPresetID: "mage_01",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "u2", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "hero2", zoneID: zoneID)
        )
        await cache.upsertProfile(victim)
        appState.currentProfile = actor

        do {
            _ = try await service.addXP(50, to: victim)
            #expect(Bool(false), "Expected addXP to throw unauthorized")
        } catch {
            #expect(error as? FamilyServiceError == .unauthorized)
        }

        // Cache must remain untouched — identity guard fires before any mutation.
        let cached = cache.fetchProfile(recordName: victim.id.recordName, family: victim.family.recordID.recordName)
        #expect(cached?.xpTotal == 0, "addXP must not mutate the cache when the actor is not the target profile")
    }

    @Test
    func `addXP throws unauthorized when no appState is set`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let service = XPService(cloudKit: cloudKit, cacheService: cache)

        let hero = makeHero(zoneID: zoneID, xp: 0, level: 1)
        await cache.upsertProfile(hero)

        do {
            _ = try await service.addXP(50, to: hero)
            #expect(Bool(false), "Expected addXP to throw unauthorized when appState is nil")
        } catch {
            #expect(error as? FamilyServiceError == .unauthorized)
        }
    }

    @Test
    func `addXP throws ScopeViolation when profile family does not match active family`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = XPService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let parent = Profile(
            displayName: "Parent GM",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "parent1", zoneID: zoneID),
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none),
            id: CKRecord.ID(recordName: "parent1", zoneID: zoneID)
        )
        appState.currentProfile = parent
        appState.family = Family(
            name: "Guild 1",
            createdBy: parent.id,
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )

        // Hero belongs to a DIFFERENT family
        let foreignHero = Profile(
            displayName: "Foreign Hero",
            avatarClass: .mage,
            avatarPresetID: "mage_01",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "foreign_hero", zoneID: zoneID),
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: "foreign_fam", zoneID: zoneID), action: .none),
            id: CKRecord.ID(recordName: "foreign_hero", zoneID: zoneID)
        )

        do {
            _ = try await service.addXP(50, to: foreignHero)
            #expect(Bool(false), "Expected addXP to throw ScopeViolation for cross-family grant")
        } catch let error as ScopeViolation {
            #expect(error == ScopeViolation.familyMismatch(active: "fam1", supplied: "foreign_fam"))
        }
    }
}
