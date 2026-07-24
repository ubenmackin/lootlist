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
}
