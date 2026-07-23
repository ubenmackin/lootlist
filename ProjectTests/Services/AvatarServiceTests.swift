import Foundation
import Testing
import CloudKit
@testable import LootList

@MainActor
struct AvatarServiceTests {

    @Test("Avatar preset resolution for classes and IDs")
    func testAvatarPresetResolution() {
        let presetKnight = AvatarPreset.resolve(.knight, id: "knight_01")
        #expect(presetKnight == .knightV1)

        let presetMage = AvatarPreset.resolve(.mage, id: "mage_02")
        #expect(presetMage == .mageV2)

        let presetRogue = AvatarPreset.resolve(.rogue, id: "rogue_03")
        #expect(presetRogue == .rogueV3)
    }

    @Test("Presets list per AvatarClass")
    func testPresetsForClass() {
        let knights = AvatarPreset.presets(for: .knight)
        #expect(knights.count == 4)
        #expect(knights.contains(.knightV1))
        #expect(knights.contains(.knightV4))
    }

    @Test("AvatarRenderSpec generation from Profile")
    func testRenderSpec() {
        let dummyZone = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = CloudKitService(zoneID: dummyZone)
        let xpService = XPService(cloudKit: cloudKit)
        let avatarService = AvatarService(xp: xpService)

        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: dummyZone), action: .none)
        let userID = CKRecord.ID(recordName: "user1", zoneID: dummyZone)

        var profile = Profile(
            displayName: "Sir Lancelot",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .hero,
            iCloudUserID: userID,
            family: familyRef,
            id: CKRecord.ID(recordName: "hero1", zoneID: dummyZone)
        )
        profile.xp = 1000
        profile.level = 5

        let spec = avatarService.renderSpec(for: profile)
        #expect(spec.displayName == "Sir Lancelot")
        #expect(spec.preset == .knightV1)
        #expect(spec.levelTitle == "Champion")
        #expect(spec.equippedAccessory == "accessory.level.5")
    }

    @Test("Accessory glyph mapping")
    func testAccessoryGlyphs() {
        #expect(AvatarService.accessoryGlyph(for: "accessory.level.5") == "sparkles")
        #expect(AvatarService.accessoryGlyph(for: "accessory.level.10") == "bolt.fill")
        #expect(AvatarService.accessoryGlyph(for: "accessory.level.15") == "star.fill")
        #expect(AvatarService.accessoryGlyph(for: "accessory.level.20") == "flame.fill")
        #expect(AvatarService.accessoryGlyph(for: "invalid.key") == nil)
    }
}
