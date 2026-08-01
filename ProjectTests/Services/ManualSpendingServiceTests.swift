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
        let service = ManualSpendingService(cloudKit: cloudKit, cacheService: cache)

        let hero = makeHero(zoneID)
        let family = makeFamily(zoneID)

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
        let service = ManualSpendingService(cloudKit: cloudKit, cacheService: cache)

        let hero = makeHero(zoneID)
        let familyRef = makeFamilyRef(zoneID)

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
}
