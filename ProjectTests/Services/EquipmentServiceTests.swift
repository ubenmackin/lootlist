//
//  EquipmentServiceTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct EquipmentServiceTests {
    struct TestEnvironment {
        let equipmentService: EquipmentService
        let gemService: GemService
        let cache: CacheService
        let profile: Profile
    }

    private func makeIsolatedEnvironment() throws -> TestEnvironment {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID

        let cache = try CacheService(inMemory: true)
        let sound = SoundManager()
        let gemService = GemService(cloudKitService: cloudKit, cacheService: cache, soundManager: sound)
        let equipmentService = EquipmentService(cloudKitService: cloudKit, cacheService: cache)

        let familyID = CKRecord.ID(recordName: "test-family", zoneID: zoneID)
        let familyRef = CKRecord.Reference(recordID: familyID, action: .none)
        let userID = CKRecord.ID(recordName: "test-user", zoneID: zoneID)

        let profileID = CKRecord.ID(recordName: "hero-1", zoneID: zoneID)
        var profile = Profile(
            displayName: "Test Hero",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .hero,
            iCloudUserID: userID,
            family: familyRef,
            id: profileID
        )
        profile.level = 5

        let profileCache = ProfileCache(from: profile)
        cache.context?.insert(profileCache)
        try? cache.context?.save()

        return TestEnvironment(
            equipmentService: equipmentService,
            gemService: gemService,
            cache: cache,
            profile: profile
        )
    }

    @Test
    func `gem ledger IDs are stable for the same logical event`() {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let first = GemLedger.deterministicRecordID(
            profileRecordName: "hero-1",
            eventKey: "purchase-item-1",
            source: "shopPurchase",
            zoneID: zoneID
        )
        let retry = GemLedger.deterministicRecordID(
            profileRecordName: "hero-1",
            eventKey: "purchase-item-1",
            source: "shopPurchase",
            zoneID: zoneID
        )
        let differentEvent = GemLedger.deterministicRecordID(
            profileRecordName: "hero-1",
            eventKey: "purchase-item-2",
            source: "shopPurchase",
            zoneID: zoneID
        )

        #expect(first == retry)
        #expect(first != differentEvent)
    }

    // MARK: - Catalog & Model Tests

    @Test
    func `catalog has 15+ items and covers all categories`() {
        #expect(ShopItem.catalog.count >= 15)

        for category in ShopCategory.allCases {
            let items = ShopItem.items(for: category)
            #expect(!items.isEmpty, "Category \(category.displayName) should contain catalog items")
        }
    }

    @Test
    func `catalog item attributes are valid`() {
        for item in ShopItem.catalog {
            #expect(!item.id.isEmpty)
            #expect(!item.name.isEmpty)
            #expect(!item.description.isEmpty)
            #expect(!item.iconSystemName.isEmpty)
            #expect(!item.layerKey.isEmpty)
            #expect(item.gemPrice >= 30 && item.gemPrice <= 300)
            #expect(item.requiredLevel >= 1 && item.requiredLevel <= 10)
        }
    }

    @Test
    func `lookup item by id`() {
        let crown = ShopItem.item(withId: "headwear_golden_crown")
        #expect(crown != nil)
        #expect(crown?.name == "Golden Crown")
        #expect(crown?.category == .headwear)
        #expect(crown?.gemPrice == 120)
        #expect(crown?.requiredLevel == 5)

        let nonExistent = ShopItem.item(withId: "non_existent_item")
        #expect(nonExistent == nil)
    }

    @Test
    func `shop category properties`() {
        #expect(ShopCategory.headwear.displayName == "Headwear")
        #expect(ShopCategory.weapons.displayName == "Weapons")
        #expect(ShopCategory.capes.displayName == "Capes")
        #expect(ShopCategory.auras.displayName == "Auras")
        #expect(ShopCategory.companions.displayName == "Companions")

        #expect(!ShopCategory.headwear.iconSystemName.isEmpty)
        #expect(!ShopCategory.weapons.iconSystemName.isEmpty)
        #expect(!ShopCategory.capes.iconSystemName.isEmpty)
        #expect(!ShopCategory.auras.iconSystemName.isEmpty)
        #expect(!ShopCategory.companions.iconSystemName.isEmpty)
    }

    // MARK: - EquipmentService Ownership & Equip Tests

    @Test
    func `initial ownership and equip state is empty`() throws {
        let env = try makeIsolatedEnvironment()

        let crown = try #require(ShopItem.item(withId: "headwear_golden_crown"))
        #expect(!env.equipmentService.isOwned(item: crown, profile: env.profile))
        #expect(!env.equipmentService.isEquipped(item: crown, profile: env.profile))
        #expect(env.equipmentService.ownedItemIDs(for: env.profile).isEmpty)
        #expect(env.equipmentService.equippedItems(for: env.profile).isEmpty)
    }

    @Test
    func `purchase item success path with gem deduction and auto equip`() async throws {
        let env = try makeIsolatedEnvironment()
        let sound = SoundManager()

        try await env.gemService.creditGems(amount: 200, to: env.profile, source: "testReward", eventKey: "test-setup")
        let startingBalance = try env.gemService.balance(for: env.profile.id.recordName, familyRecordName: "test-family")
        #expect(startingBalance == 200)

        let crown = try #require(ShopItem.item(withId: "headwear_golden_crown"))
        try await env.equipmentService.buyItem(item: crown, profile: env.profile, gemService: env.gemService, soundManager: sound)

        #expect(env.equipmentService.isOwned(item: crown, profile: env.profile))
        #expect(env.equipmentService.isEquipped(item: crown, profile: env.profile))
        #expect(env.equipmentService.equippedItem(for: .headwear, profile: env.profile) == crown)

        let remainingBalance = try env.gemService.balance(for: env.profile.id.recordName, familyRecordName: "test-family")
        #expect(remainingBalance == 80)
    }

    @Test
    func `repeated logical gem operations do not duplicate local ledger rows`() async throws {
        let env = try makeIsolatedEnvironment()

        try await env.gemService.creditGems(
            amount: 200,
            to: env.profile,
            source: "testReward",
            eventKey: "setup-event"
        )
        try await env.gemService.creditGems(
            amount: 200,
            to: env.profile,
            source: "testReward",
            eventKey: "setup-event"
        )
        #expect(try env.gemService.balance(for: "hero-1", familyRecordName: "test-family") == 200)

        let firstSpend = try await env.gemService.spendGems(
            amount: 120,
            from: env.profile,
            itemID: "headwear_golden_crown",
            on: "Golden Crown",
            eventKey: "purchase-event"
        )
        let retrySpend = try await env.gemService.spendGems(
            amount: 120,
            from: env.profile,
            itemID: "headwear_golden_crown",
            on: "Golden Crown",
            eventKey: "purchase-event"
        )

        #expect(firstSpend)
        #expect(retrySpend)
        #expect(try env.gemService.balance(for: "hero-1", familyRecordName: "test-family") == 80)
        #expect(env.cache.fetchGemLedgers(family: "test-family").count == 2)
    }

    @Test
    func `purchase item fails when level too low`() async throws {
        let env = try makeIsolatedEnvironment()
        var profile = env.profile
        let sound = SoundManager()

        profile.level = 2
        try await env.gemService.creditGems(amount: 300, to: profile, source: "testReward", eventKey: "test-setup")

        let crown = try #require(ShopItem.item(withId: "headwear_golden_crown"))

        await #expect(throws: EquipmentError.levelTooLow(required: 5)) {
            try await env.equipmentService.buyItem(item: crown, profile: profile, gemService: env.gemService, soundManager: sound)
        }

        #expect(!env.equipmentService.isOwned(item: crown, profile: profile))
    }

    @Test
    func `purchase item fails when insufficient gems`() async throws {
        let env = try makeIsolatedEnvironment()
        let sound = SoundManager()

        try await env.gemService.creditGems(amount: 50, to: env.profile, source: "testReward", eventKey: "test-setup")

        let crown = try #require(ShopItem.item(withId: "headwear_golden_crown"))

        await #expect(throws: EquipmentError.insufficientGems(required: 120, current: 50)) {
            try await env.equipmentService.buyItem(item: crown, profile: env.profile, gemService: env.gemService, soundManager: sound)
        }

        #expect(!env.equipmentService.isOwned(item: crown, profile: env.profile))
    }

    @Test
    func `purchase item fails when already owned`() async throws {
        let env = try makeIsolatedEnvironment()
        let sound = SoundManager()

        try await env.gemService.creditGems(amount: 300, to: env.profile, source: "testReward", eventKey: "test-setup")
        let crown = try #require(ShopItem.item(withId: "headwear_golden_crown"))

        try await env.equipmentService.buyItem(item: crown, profile: env.profile, gemService: env.gemService, soundManager: sound)
        #expect(env.equipmentService.isOwned(item: crown, profile: env.profile))

        await #expect(throws: EquipmentError.alreadyOwned) {
            try await env.equipmentService.buyItem(item: crown, profile: env.profile, gemService: env.gemService, soundManager: sound)
        }
    }

    @Test
    func `toggle equip when owned and unowned`() async throws {
        let env = try makeIsolatedEnvironment()
        let sound = SoundManager()

        let crown = try #require(ShopItem.item(withId: "headwear_golden_crown"))

        await #expect(throws: EquipmentError.notOwned) {
            try await env.equipmentService.toggleEquip(item: crown, profile: env.profile, gemService: env.gemService, soundManager: sound)
        }

        try await env.gemService.creditGems(amount: 200, to: env.profile, source: "testReward", eventKey: "test-setup")
        try await env.equipmentService.buyItem(item: crown, profile: env.profile, gemService: env.gemService, soundManager: sound)
        #expect(env.equipmentService.isEquipped(item: crown, profile: env.profile))

        try await env.equipmentService.toggleEquip(item: crown, profile: env.profile, gemService: env.gemService, soundManager: sound)
        #expect(!env.equipmentService.isEquipped(item: crown, profile: env.profile))
        #expect(env.equipmentService.equippedItem(for: .headwear, profile: env.profile) == nil)

        try await env.equipmentService.toggleEquip(item: crown, profile: env.profile, gemService: env.gemService, soundManager: sound)
        #expect(env.equipmentService.isEquipped(item: crown, profile: env.profile))
        #expect(env.equipmentService.equippedItem(for: .headwear, profile: env.profile) == crown)
    }

    @Test
    func `multiple category equipping and explicit unequip`() throws {
        let env = try makeIsolatedEnvironment()

        let bandana = try #require(ShopItem.item(withId: "headwear_bandana"))
        let sword = try #require(ShopItem.item(withId: "weapon_flaming_sword"))
        let cloak = try #require(ShopItem.item(withId: "cape_shadow_cloak"))
        let aura = try #require(ShopItem.item(withId: "aura_cosmic"))
        let dragon = try #require(ShopItem.item(withId: "companion_dragon_hatchling"))

        env.equipmentService.equip(item: bandana, profile: env.profile)
        env.equipmentService.equip(item: sword, profile: env.profile)
        env.equipmentService.equip(item: cloak, profile: env.profile)
        env.equipmentService.equip(item: aura, profile: env.profile)
        env.equipmentService.equip(item: dragon, profile: env.profile)

        let equipped = env.equipmentService.equippedItems(for: env.profile)
        #expect(equipped.count == 5)
        #expect(equipped[.headwear] == bandana)
        #expect(equipped[.weapons] == sword)
        #expect(equipped[.capes] == cloak)
        #expect(equipped[.auras] == aura)
        #expect(equipped[.companions] == dragon)

        env.equipmentService.unequip(category: .weapons, profile: env.profile)
        #expect(env.equipmentService.equippedItem(for: .weapons, profile: env.profile) == nil)
        #expect(env.equipmentService.equippedItems(for: env.profile).count == 4)
    }

    @Test
    func `buyItem succeeds when cached profile level meets requirement despite stale profile snapshot`() async throws {
        let env = try makeIsolatedEnvironment()
        let sound = SoundManager()

        try await env.gemService.creditGems(amount: 300, to: env.profile, source: "testReward", eventKey: "test-setup")
        let item = try #require(ShopItem.item(withId: "weapon_holy_mace"))
        #expect(item.requiredLevel == 5)

        var staleProfile = env.profile
        staleProfile.level = 1

        try await env.equipmentService.buyItem(item: item, profile: staleProfile, gemService: env.gemService, soundManager: sound)
        #expect(env.equipmentService.isOwned(item: item, profile: env.profile))
    }

    @Test
    func `payout and rt recordNames are stable and zone independent`() {
        let zoneA = CKRecordZone.ID(zoneName: "ZoneA", ownerName: "OwnerA")
        let zoneB = CKRecordZone.ID(zoneName: "ZoneB", ownerName: "OwnerB")
        let periodName = "period-fam1-hero1-9999999999"
        let payoutA = CKRecord.ID(recordName: "payout-\(periodName)", zoneID: zoneA)
        let payoutB = CKRecord.ID(recordName: "payout-\(periodName)", zoneID: zoneB)
        #expect(payoutA.recordName == payoutB.recordName)
        #expect(payoutA.recordName == "payout-period-fam1-hero1-9999999999")

        let rtA = CKRecord.ID(recordName: "rt-\(periodName)", zoneID: zoneA)
        let rtB = CKRecord.ID(recordName: "rt-\(periodName)", zoneID: zoneB)
        #expect(rtA.recordName == rtB.recordName)
        #expect(rtA.recordName == "rt-period-fam1-hero1-9999999999")
        #expect(payoutA.recordName != rtA.recordName)
    }

    @Test
    func `purchaseRecordID deterministic and zone independent`() {
        let zoneA = CKRecordZone.ID(zoneName: "ZoneA", ownerName: "OwnerA")
        let zoneB = CKRecordZone.ID(zoneName: "ZoneB", ownerName: "OwnerB")
        let fallbackA = GemLedger.purchaseRecordID(profileRecordName: "hero-1", itemID: "weapon_flaming_sword", eventKey: nil, zoneID: zoneA)
        let fallbackB = GemLedger.purchaseRecordID(profileRecordName: "hero-1", itemID: "weapon_flaming_sword", eventKey: nil, zoneID: zoneB)
        #expect(fallbackA.recordName == fallbackB.recordName)
        #expect(fallbackA.recordName == "gem-hero-1-purchase-weapon_flaming_sword-shopPurchase")

        let explicitA = GemLedger.purchaseRecordID(profileRecordName: "hero-1", itemID: "weapon_flaming_sword", eventKey: "shopPurchase-weapon_flaming_sword", zoneID: zoneA)
        let explicitB = GemLedger.purchaseRecordID(profileRecordName: "hero-1", itemID: "weapon_flaming_sword", eventKey: "shopPurchase-weapon_flaming_sword", zoneID: zoneB)
        #expect(explicitA.recordName == explicitB.recordName)
    }

    @Test
    func `reward event recordName stable and zone independent`() {
        let zoneA = CKRecordZone.ID(zoneName: "ZoneA", ownerName: "OwnerA")
        let zoneB = CKRecordZone.ID(zoneName: "ZoneB", ownerName: "OwnerB")
        let idA = RewardEvent.recordID(completionRecordName: "completion-abc", zoneID: zoneA)
        let idB = RewardEvent.recordID(completionRecordName: "completion-abc", zoneID: zoneB)
        #expect(idA.recordName == idB.recordName)
        #expect(idA.recordName == "reward-completion-abc")
    }

    @Test
    func `concurrent duplicate eventKey via equipment purchase does not double mint`() async throws {
        let env = try makeIsolatedEnvironment()
        try await env.gemService.creditGems(amount: 500, to: env.profile, source: "testReward", eventKey: "setup-concurrent-buy")
        let sound = SoundManager()
        let crown = try #require(ShopItem.item(withId: "headwear_golden_crown"))

        var tasks: [Task<Void, Never>] = []
        for _ in 0 ..< 5 {
            tasks.append(Task { @MainActor in
                try? await env.equipmentService.buyItem(item: crown, profile: env.profile, gemService: env.gemService, soundManager: sound)
            })
        }
        for task in tasks {
            _ = await task.value
        }

        #expect(env.equipmentService.isOwned(item: crown, profile: env.profile))
        let ledgers = env.cache.fetchGemLedgers(family: "test-family")
        let purchaseLedgers = ledgers.filter { $0.recordName.contains("headwear_golden_crown") }
        #expect(purchaseLedgers.count == 1, "Concurrent duplicate purchase must collapse to a single ledger row")
        let balance = try env.gemService.balance(for: "hero-1", familyRecordName: "test-family")
        #expect(balance == 380, "500 - 120 must be charged exactly once despite concurrent attempts")
    }
}
