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
        let dummyZone = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let service = XPService(cloudKit: CloudKitService(zoneID: dummyZone))

        #expect(service.level(forXP: 0) == 1)
        #expect(service.level(forXP: 50) == 1)
        #expect(service.level(forXP: 100) == 2)
        #expect(service.level(forXP: 250) == 2)
        #expect(service.level(forXP: 300) == 3)
        #expect(service.level(forXP: 1000) == 5)
    }

    @Test
    func `level progress calculations`() {
        let dummyZone = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let service = XPService(cloudKit: CloudKitService(zoneID: dummyZone))

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
        let service = XPService(cloudKit: CloudKitService(zoneID: dummyZone))
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

    // MARK: - addXP snapshot-rollback (D2 invariant)

    private enum MockError: Error, Equatable {
        case saveFailed
    }

    @MainActor
    private final class FailingCloudKitService: CloudKitServicing {
        func save<T: CloudKitRecord>(_: T,
                                     in _: CKRecordZone.ID?,
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
        let cloudKit = CloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let service = XPService(cloudKit: cloudKit, cacheService: cache)

        let hero = makeHero(zoneID: zoneID, xp: 100, level: 1)
        cache.upsertProfile(hero)

        let saved = try await service.addXP(50, to: hero)

        // (a) success: cache holds the saved (inflated) profile.
        #expect(saved.xp == 150)
        #expect(saved.level == 2)
        let cached = cache.fetchProfile(recordName: hero.id.recordName)
        #expect(cached != nil)
        #expect(cached?.xpTotal == 150)
        #expect(cached?.level == 2)
    }

    @Test
    func `addXP on save failure rolls cache back to pre-mutation value`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = FailingCloudKitService()
        let cache = try CacheService(inMemory: true)
        let service = XPService(cloudKit: cloudKit, cacheService: cache)

        let hero = makeHero(zoneID: zoneID, xp: 100, level: 1)
        cache.upsertProfile(hero)

        let returned = try await service.addXP(50, to: hero)

        // (c) returned profile is the rolled-back value, NOT the inflated `updated`.
        #expect(returned.xp == 100, "addXP must return rolled-back profile on failure, not the inflated value")
        #expect(returned.xp != 150)
        #expect(returned.level == 1)

        // (b) cache is rolled back to the pre-mutation value.
        let cached = cache.fetchProfile(recordName: hero.id.recordName)
        #expect(cached != nil, "snapshot-rollback should restore the cached profile, not invalidate it")
        #expect(cached?.xpTotal == 100)
        #expect(cached?.level == 1)
    }

    @Test
    func `addXP on save failure with no snapshot invalidates cache and returns original`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = FailingCloudKitService()
        let cache = try CacheService(inMemory: true)
        let service = XPService(cloudKit: cloudKit, cacheService: cache)

        let hero = makeHero(zoneID: zoneID, xp: 100, level: 1)
        // Note: deliberately NOT seeded into the cache → no snapshot available.

        let returned = try await service.addXP(50, to: hero)

        // (c) returned profile is the original profile, NOT the inflated `updated`.
        #expect(returned.xp == 100, "addXP must return original profile when no snapshot exists")
        #expect(returned.xp != 150)
        #expect(returned.id == hero.id)

        // (b) cache is invalidated (no prior state to roll back to).
        let cached = cache.fetchProfile(recordName: hero.id.recordName)
        #expect(cached == nil, "invalidate-on-failure should remove the optimistically-written profile")
    }
}
