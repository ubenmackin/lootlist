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

    private final class FailingCloudKitService: CloudKitService {
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
            _ = try await service.logManual(profile: hero, family: family, description: "Test Buy", amount: 10.0)
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
}
