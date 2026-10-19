//
//  LootDropServiceTests.swift
//  LootList
//
//  Created by Ben Mackin on 10/18/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct LootDropServiceTests {
    private func makeZoneID(name: String = "LootZone") -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: name, ownerName: "LootOwner")
    }

    private struct TestFixture {
        let cloudKit: MockCloudKitService
        let cache: CacheService
        let appState: AppState
        let gemService: GemService
        let lootService: LootDropService
        let toast: ToastManager
        let sound: SoundManager
        let hero: Profile
        let family: Family
        let zoneID: CKRecordZone.ID
    }

    private func makeFixture() throws -> TestFixture {
        let defaults = UserDefaults.ephemeral()
        let zoneID = makeZoneID()
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        cloudKit.activeIsOwner = true
        let cache = try CacheService(inMemory: true, defaults: defaults)
        let appState = AppState(defaults: defaults)
        appState.cacheService = cache

        let family = ExhaustiveCacheFixtures.sharedFamily(zoneID: zoneID, name: "Loot Guild", creatorUserRecordName: "hero1")
        var hero = ExhaustiveCacheFixtures.sharedHero(zoneID: zoneID, displayName: "Hero", iCloudRecordName: "hero1")
        hero.family = CKRecord.Reference(recordID: family.id, action: .none)
        cache.context?.insert(FamilyCache(from: family))
        cache.context?.insert(ProfileCache(from: hero))
        _ = cache.saveContext()
        cloudKit.seedMockRecords([family, hero])
        appState.family = family
        appState.familyZoneID = zoneID
        appState.currentProfile = hero
        appState.isZoneOwner = true
        appState.authStatus = .authenticated

        let toast = ToastManager()
        let sound = SoundManager()
        let gemService = GemService(cloudKitService: cloudKit, cacheService: cache, toastManager: toast, appState: appState, soundManager: sound)
        let lootService = LootDropService(gemService: gemService, toastManager: toast, soundManager: sound)

        return TestFixture(
            cloudKit: cloudKit,
            cache: cache,
            appState: appState,
            gemService: gemService,
            lootService: lootService,
            toast: toast,
            sound: sound,
            hero: hero,
            family: family,
            zoneID: zoneID
        )
    }

    private func lootLedgerID(hero: Profile, eventKey: String, zoneID: CKRecordZone.ID) -> CKRecord.ID {
        GemLedger.deterministicRecordID(
            profileRecordName: hero.id.recordName,
            eventKey: eventKey,
            source: "lootDrop",
            zoneID: zoneID
        )
    }

    @Test
    func `rollAndCredit with RPG flag off returns nil and creates no ledger`() async throws {
        let fixture = try makeFixture()
        let hero = fixture.hero
        let family = fixture.family
        let zoneID = fixture.zoneID

        // Forced provider guarantees a drop would fire if the gate were missing.
        let forcedDrop = LootDrop(gemAmount: 25, description: "Forced Pouch", rarity: .rare)
        fixture.lootService.rollProvider = { _, _ in forcedDrop }

        try await RPGFlagGate.withRPGFlag(false) {
            let credited = await fixture.lootService.rollAndCredit(
                questRarity: .rare,
                streakDays: 3,
                to: hero,
                eventKey: "loot-flagoff"
            )
            #expect(credited == nil)
            #expect(fixture.lootService.pendingPresentation == nil)

            let ledgerID = lootLedgerID(hero: hero, eventKey: "loot-flagoff", zoneID: zoneID)
            #expect(fixture.cache.fetchGemLedger(recordName: ledgerID.recordName, family: family.id.recordName) == nil)
            let balance = try fixture.gemService.balance(for: hero.id.recordName, familyRecordName: family.id.recordName)
            #expect(balance == 0)
            #expect(fixture.sound.lastPlayedEvent == nil)
            #expect(fixture.toast.toasts.isEmpty)
        }
    }

    @Test
    func `rollAndCredit with RPG flag on rolls and credits the ledger`() async throws {
        let fixture = try makeFixture()
        let hero = fixture.hero
        let family = fixture.family
        let zoneID = fixture.zoneID

        let forcedDrop = LootDrop(gemAmount: 25, description: "Forced Pouch", rarity: .rare)
        fixture.lootService.rollProvider = { _, _ in forcedDrop }

        try await RPGFlagGate.withRPGFlag(true) {
            let credited = await fixture.lootService.rollAndCredit(
                questRarity: .rare,
                streakDays: 3,
                to: hero,
                eventKey: "loot-flagon"
            )
            #expect(credited == forcedDrop)
            #expect(fixture.lootService.pendingPresentation == forcedDrop)

            let ledgerID = lootLedgerID(hero: hero, eventKey: "loot-flagon", zoneID: zoneID)
            #expect(fixture.cache.fetchGemLedger(recordName: ledgerID.recordName, family: family.id.recordName) != nil)
            let balanceAfterCredit = try fixture.gemService.balance(for: hero.id.recordName, familyRecordName: family.id.recordName)
            #expect(balanceAfterCredit == 25)

            // Second roll with the same eventKey stays idempotent and returns nil.
            let duplicate = await fixture.lootService.rollAndCredit(
                questRarity: .rare,
                streakDays: 3,
                to: hero,
                eventKey: "loot-flagon"
            )
            #expect(duplicate == nil)
            let balanceAfterDuplicateRoll = try fixture.gemService.balance(for: hero.id.recordName, familyRecordName: family.id.recordName)
            #expect(balanceAfterDuplicateRoll == 25)
        }
    }

    @Test
    func `creditGems with RPG flag off persists ledger without sound or toast`() async throws {
        let fixture = try makeFixture()
        let hero = fixture.hero
        let family = fixture.family
        let zoneID = fixture.zoneID

        try await RPGFlagGate.withRPGFlag(false) {
            let credited = try await fixture.gemService.creditGems(
                amount: 10,
                to: hero,
                source: "lootDrop",
                eventKey: "wallet-flagoff",
                detail: "Test Pouch"
            )
            #expect(credited == true)

            let ledgerID = GemLedger.deterministicRecordID(
                profileRecordName: hero.id.recordName,
                eventKey: "wallet-flagoff",
                source: "lootDrop",
                zoneID: zoneID
            )
            #expect(fixture.cache.fetchGemLedger(recordName: ledgerID.recordName, family: family.id.recordName) != nil)
            let balance = try fixture.gemService.balance(for: hero.id.recordName, familyRecordName: family.id.recordName)
            #expect(balance == 10)

            #expect(fixture.sound.lastPlayedEvent == nil)
            #expect(fixture.toast.toasts.isEmpty)
        }
    }

    @Test
    func `creditGems with RPG flag on plays sound and shows toast`() async throws {
        let fixture = try makeFixture()
        let hero = fixture.hero
        let family = fixture.family
        let zoneID = fixture.zoneID

        try await RPGFlagGate.withRPGFlag(true) {
            let credited = try await fixture.gemService.creditGems(
                amount: 10,
                to: hero,
                source: "lootDrop",
                eventKey: "wallet-flagon",
                detail: "Test Pouch"
            )
            #expect(credited == true)
            #expect(fixture.sound.lastPlayedEvent == .gemEarned)
            #expect(fixture.toast.toasts.contains { $0.message == "+10 Gems! 💎" && $0.type == .success })

            let ledgerID = GemLedger.deterministicRecordID(
                profileRecordName: hero.id.recordName,
                eventKey: "wallet-flagon",
                source: "lootDrop",
                zoneID: zoneID
            )
            #expect(fixture.cache.fetchGemLedger(recordName: ledgerID.recordName, family: family.id.recordName) != nil)
            let balance = try fixture.gemService.balance(for: hero.id.recordName, familyRecordName: family.id.recordName)
            #expect(balance == 10)
        }
    }
}
