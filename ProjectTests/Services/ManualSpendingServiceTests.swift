//
//  ManualSpendingServiceTests.swift
//  LootList
//
//  Created by OpenCode on 2026-08-01.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct ManualSpendingServiceTests {
    // MARK: - Mock Infrastructure

    private enum MockError: Error, Equatable {
        case saveFailed
    }

    private final class FailingCloudKitService: MockCloudKitService {
        init(zoneID: CKRecordZone.ID? = nil) {
            super.init()
            self.activeFamilyZoneID = zoneID
        }

        override func save<T: CloudKitRecord>(
            _: T,
            in _: CKRecordZone.ID? = nil,
            using _: CKDatabase? = nil
        ) async throws -> T {
            throw MockError.saveFailed
        }

        override func delete(
            _: CKRecord.ID,
            in _: CKRecordZone.ID? = nil,
            using _: CKDatabase? = nil
        ) async throws {
            throw MockError.saveFailed
        }
    }

    // MARK: - Shared Fixtures

    private func makeZoneID() -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
    }

    private func makeFamilyRef(_ zoneID: CKRecordZone.ID) -> CKRecord.Reference {
        CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID),
            action: .none
        )
    }

    private func makeHero(_ zoneID: CKRecordZone.ID) -> Profile {
        let userID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
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

    private func makeFamily(_ zoneID: CKRecordZone.ID) -> Family {
        Family(
            name: "Test Guild",
            createdBy: CKRecord.ID(recordName: "parent1", zoneID: zoneID),
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
    }

    // MARK: - Tests

    @Test
    func `manual spending service logManual invalidates on save failure`() async throws {
        let zoneID = makeZoneID()
        let cloudKit = FailingCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = ManualSpendingService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let hero = makeHero(zoneID)
        let family = makeFamily(zoneID)
        appState.currentProfile = hero

        do {
            _ = try await service.logManual(profile: hero, family: family, familyRecordName: family.id.recordName, description: "Test Buy", amount: 10.0)
            #expect(Bool(false), "Expected save to throw")
        } catch {
            #expect(error is MockError)
        }

        let cached = cache.fetchLedgerEntries(profileRecordName: hero.id.recordName)
        #expect(cached.isEmpty, "LedgerEntry must be invalidated after save failure for new manual entry")
    }

    @Test
    func `manual spending service delete restores snapshot on save failure`() async throws {
        let zoneID = makeZoneID()
        let cloudKit = FailingCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = ManualSpendingService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let hero = makeHero(zoneID)
        let familyRef = makeFamilyRef(zoneID)
        appState.currentProfile = hero

        let entry = LedgerEntry(
            profile: CKRecord.Reference(recordID: hero.id, action: .none),
            amount: -15.0,
            description: "Existing item",
            date: Date(),
            source: "manual",
            family: familyRef
        )
        cache.upsertLedgerEntry(entry)

        do {
            try await service.delete(entry)
            #expect(Bool(false), "Expected delete to throw")
        } catch {
            #expect(error is MockError)
        }

        let cached = cache.fetchLedgerEntries(profileRecordName: hero.id.recordName)
        #expect(!cached.isEmpty, "LedgerEntry must be restored from snapshot after delete failure")
        #expect(cached.first?.amount == -15.0)
    }

    // MARK: - Identity guards

    private func makeParent(_ zoneID: CKRecordZone.ID) -> Profile {
        let userID = CKRecord.ID(recordName: "parent1", zoneID: zoneID)
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

    @Test
    func `logManual throws unauthorized when actor is not target profile`() async throws {
        let zoneID = makeZoneID()
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = ManualSpendingService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let actor = makeParent(zoneID)
        let victimID = CKRecord.ID(recordName: "hero2", zoneID: zoneID)
        let victim = Profile(
            displayName: "Victim Hero",
            avatarClass: .mage,
            avatarPresetID: "mage_01",
            role: .hero,
            iCloudUserID: victimID,
            family: makeFamilyRef(zoneID),
            id: victimID
        )
        let family = makeFamily(zoneID)
        appState.currentProfile = actor

        do {
            _ = try await service.logManual(
                profile: victim,
                family: family,
                familyRecordName: family.id.recordName,
                description: "Should not save",
                amount: 10.0
            )
            #expect(Bool(false), "Expected logManual to throw unauthorized")
        } catch {
            #expect(error as? FamilyServiceError == .unauthorized)
        }

        let cached = cache.fetchLedgerEntries(profileRecordName: victim.id.recordName)
        #expect(cached.isEmpty, "logManual must not write when the actor is not the target profile")
    }

    @Test
    func `delete throws unauthorized when actor is neither entry owner nor parent`() async throws {
        let zoneID = makeZoneID()
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = ManualSpendingService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let actor = makeHero(zoneID)
        let otherHeroID = CKRecord.ID(recordName: "hero2", zoneID: zoneID)
        let entry = LedgerEntry(
            profile: CKRecord.Reference(recordID: otherHeroID, action: .none),
            amount: -10.0,
            description: "Another hero's entry",
            date: Date(),
            source: "manual",
            family: makeFamilyRef(zoneID)
        )
        cache.upsertLedgerEntry(entry)
        appState.currentProfile = actor

        do {
            try await service.delete(entry)
            #expect(Bool(false), "Expected delete to throw unauthorized")
        } catch {
            #expect(error as? FamilyServiceError == .unauthorized)
        }

        // The entry must remain in cache — the unauthorized delete must not invalidate it.
        let cached = cache.fetchLedgerEntries(profileRecordName: otherHeroID.recordName)
        #expect(cached.first?.amount == -10.0, "unauthorized delete must not touch the entry")
    }

    @Test
    func `delete succeeds when actor is the entry owner`() async throws {
        let zoneID = makeZoneID()
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = ManualSpendingService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let hero = makeHero(zoneID)
        let entry = LedgerEntry(
            profile: CKRecord.Reference(recordID: hero.id, action: .none),
            amount: -10.0,
            description: "Hero's own entry",
            date: Date(),
            source: "manual",
            family: makeFamilyRef(zoneID)
        )
        cache.upsertLedgerEntry(entry)
        appState.currentProfile = hero

        try await service.delete(entry)

        let cached = cache.fetchLedgerEntries(profileRecordName: hero.id.recordName)
        #expect(cached.isEmpty, "self-owned entry should be deleted")
    }

    @Test
    func `delete succeeds when actor is a parent`() async throws {
        let zoneID = makeZoneID()
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = ManualSpendingService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let parent = makeParent(zoneID)
        let heroID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        let entry = LedgerEntry(
            profile: CKRecord.Reference(recordID: heroID, action: .none),
            amount: -10.0,
            description: "Hero's entry under parent oversight",
            date: Date(),
            source: "manual",
            family: makeFamilyRef(zoneID)
        )
        cache.upsertLedgerEntry(entry)
        appState.currentProfile = parent

        try await service.delete(entry)

        let cached = cache.fetchLedgerEntries(profileRecordName: heroID.recordName)
        #expect(cached.isEmpty, "parent should be able to delete a hero's ledger entry")
    }

    // MARK: - Snapshot fetch family scoping

    /// `logManual` must scope its optimistic snapshot fetch to the active
    /// family, and keep that scope through the rollback re-fetch the
    /// save-failure path reaches. The snapshot lookup is keyed by the
    /// freshly-generated `entry.id.recordName`, which no pre-existing row can
    /// match, so the scoping is not observable through cache *contents* — a
    /// prior attempt that forced the snapshot result to nothing could not tell
    /// a scoped fetch from an unscoped one. This test therefore captures the
    /// `family:` scope passed to `fetchLedgerEntries` during `logManual`, and
    /// asserts both the pre-save snapshot fetch and the rollback
    /// `fetchCurrent` were scoped to the active family. Removing the
    /// family scoping flips the recorded scope to nil and fails the assertion.
    @Test
    func `logManual scopes optimistic snapshot fetch to active familyRecordName`() async throws {
        let zoneID = makeZoneID()
        // Force the rollback path so `logManual`'s snapshot fetch AND the
        // rollback `fetchCurrent` re-fetch both run (the save-failure branch
        // is the only path that consults the scoped re-fetch).
        let cloudKit = FailingCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let service = ManualSpendingService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let familyA = Family(
            name: "Family A",
            createdBy: CKRecord.ID(recordName: "parentA", zoneID: zoneID),
            id: CKRecord.ID(recordName: "famA", zoneID: zoneID)
        )
        let familyB = Family(
            name: "Family B",
            createdBy: CKRecord.ID(recordName: "parentB", zoneID: zoneID),
            id: CKRecord.ID(recordName: "famB", zoneID: zoneID)
        )
        cache.upsertFamily(familyA)
        cache.upsertFamily(familyB)

        let heroRefA = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        let familyRefA = CKRecord.Reference(recordID: familyA.id, action: .none)
        let hero = Profile(
            displayName: "Hero A",
            avatarClass: .mage,
            avatarPresetID: "mage_01",
            role: .hero,
            iCloudUserID: heroRefA,
            family: familyRefA,
            id: heroRefA
        )
        cache.upsertProfile(hero)

        // Legacy ledger row from a prior cross-family race: the same
        // `profileRecordName` also exists under familyB, so an unscoped
        // snapshot fetch would span both families and an unscoped rollback
        // re-fetch could restore/invalidate across the boundary.
        let legacyFamilyB = LedgerEntryCache(
            recordName: "legacy_famB_entry",
            profileRecordName: hero.id.recordName,
            familyRecordName: familyB.id.recordName,
            amount: -7.5,
            entryDescription: "Spent in the old family",
            date: Date().addingTimeInterval(-3600),
            source: "manual",
            changeTag: "v1"
        )
        cache.upsertLedgerEntry(legacyFamilyB.toLedgerEntry(zoneID: zoneID))

        appState.currentProfile = hero
        appState.family = familyA
        // Ignore the seeding fetches so only `logManual`'s own fetches count.
        cache.ledgerEntryFetchScopes = []

        // Both the pre-save snapshot capture and the rollback re-fetch must be
        // scoped to the active family — never a nil/unscoped ledger fetch.
        do {
            _ = try await service.logManual(
                profile: hero,
                family: familyA,
                familyRecordName: familyA.id.recordName,
                description: "New sword",
                amount: 12.0
            )
            #expect(Bool(false), "Expected save to throw")
        } catch {
            #expect(error is MockError)
        }

        let scopes = cache.ledgerEntryFetchScopes
        #expect(scopes.count == 2, "snapshot + rollback re-fetch should each make one scoped ledger fetch")
        #expect(scopes.allSatisfy { $0 == familyA.id.recordName },
                "every logManual ledger fetch must be scoped to the active family, got \(scopes)")

        // New manual landing is invalidated on failure; the optimistic write
        // never lands in either family.
        let familyARows = cache.fetchLedgerEntries(profileRecordName: hero.id.recordName, family: familyA.id.recordName)
        #expect(familyARows.isEmpty, "failed manual entry must not persist in familyA")

        // The other family's cache slice is untouched — neither the snapshot
        // nor the rollback may read into familyB.
        let familyBRows = cache.fetchLedgerEntries(profileRecordName: hero.id.recordName, family: familyB.id.recordName)
        #expect(familyBRows.count == 1, "logManual must not touch the other family's cache slice")
        #expect(familyBRows.first?.recordName == "legacy_famB_entry")
        #expect(familyBRows.first?.changeTag == "v1")
    }
}
