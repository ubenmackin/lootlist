//
//  SpendingServiceTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/31/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

// WHY: This file mirrors ManualSpendingServiceTests deterministic guarantees.
// All ledger money records use deterministic IDs so CloudKit dedupes across
// devices; tests assert same payloads converge and divergent payloads get
// distinct deterministic names without random UUIDs.

@MainActor
struct DeterministicSpendingIDTests {
    private func makeZoneID() -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
    }

    private func makeFamily(_ zoneID: CKRecordZone.ID) -> Family {
        Family(name: "Test Guild", createdBy: CKRecord.ID(recordName: "parent1", zoneID: zoneID), id: CKRecord.ID(recordName: "fam1", zoneID: zoneID))
    }

    private func makeHero(_ zoneID: CKRecordZone.ID) -> Profile {
        let userID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        return Profile(
            displayName: "Child Hero",
            avatarClass: .mage,
            avatarPresetID: "mage_01",
            role: .hero,
            iCloudUserID: userID,
            family: CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none),
            id: userID
        )
    }

    private func setupScope(appState: AppState, cloudKit: MockCloudKitService, family: Family, hero: Profile) {
        appState.family = family
        appState.familyZoneID = family.id.zoneID
        appState.isZoneOwner = true
        cloudKit.activeFamilyZoneID = family.id.zoneID
        cloudKit.activeIsOwner = true
        appState.currentProfile = hero
    }

    @Test
    func `cross-device same payload converges to same recordName`() async throws {
        let zoneID = makeZoneID()
        let family = makeFamily(zoneID)
        let hero = makeHero(zoneID)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let makeService: () throws -> SpendingService = {
            let ck = MockCloudKitService()
            ck.activeFamilyZoneID = zoneID
            let cache = try CacheService(inMemory: true)
            let state = AppState()
            let svc = SpendingService(cloudKit: ck, cacheService: cache, appState: state)
            state.family = family
            state.familyZoneID = family.id.zoneID
            state.isZoneOwner = true
            ck.activeIsOwner = true
            state.currentProfile = hero
            return svc
        }
        let svcA = try makeService()
        let svcB = try makeService()
        let entryA = try await svcA.logManual(
            profile: hero,
            family: family,
            familyRecordName: family.id.recordName,
            description: "Deterministic Coffee",
            amount: 4.50,
            location: "Cafe",
            date: date
        )
        let entryB = try await svcB.logManual(
            profile: hero,
            family: family,
            familyRecordName: family.id.recordName,
            description: "Deterministic Coffee",
            amount: 4.50,
            location: "Cafe",
            date: date
        )
        #expect(entryA.id.recordName == entryB.id.recordName)
        #expect(!entryA.id.recordName.lowercased().contains("uuid"))
    }

    @Test
    func `divergent payloads yield distinct deterministic names`() async throws {
        let zoneID = makeZoneID()
        let family = makeFamily(zoneID)
        let hero = makeHero(zoneID)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let desc = "Deterministic Lunch"
        let ck = MockCloudKitService()
        ck.activeFamilyZoneID = zoneID
        let cache = try CacheService(inMemory: true)
        let state = AppState()
        state.family = family
        state.familyZoneID = family.id.zoneID
        state.isZoneOwner = true
        ck.activeIsOwner = true
        state.currentProfile = hero
        let svc = SpendingService(cloudKit: ck, cacheService: cache, appState: state)
        let base = try await svc.logManual(profile: hero, family: family, familyRecordName: family.id.recordName, description: desc, amount: 9.99, location: "Cafe A", date: date)
        let baseName = base.id.recordName

        func divergent(_ location: String) async throws -> String {
            let ck2 = MockCloudKitService()
            ck2.activeFamilyZoneID = zoneID
            let cache2 = try CacheService(inMemory: true)
            let entry = LedgerEntry(
                profile: CKRecord.Reference(recordID: hero.id, action: .none),
                amount: -9.99,
                description: desc,
                location: "Cafe A",
                date: date,
                source: "manual",
                family: CKRecord.Reference(recordID: family.id, action: .none),
                id: CKRecord.ID(recordName: baseName, zoneID: zoneID)
            )
            await cache2.upsertLedgerEntry(entry)
            let s2 = AppState()
            s2.family = family
            s2.familyZoneID = family.id.zoneID
            s2.isZoneOwner = true
            ck2.activeIsOwner = true
            s2.currentProfile = hero
            let svc2 = SpendingService(cloudKit: ck2, cacheService: cache2, appState: s2)
            let divergentEntry = try await svc2.logManual(
                profile: hero,
                family: family,
                familyRecordName: family.id.recordName,
                description: desc,
                amount: 9.99,
                location: location,
                date: date
            )
            return divergentEntry.id.recordName
        }

        let n1 = try await divergent("Cafe B")
        let n2 = try await divergent("Cafe B")
        #expect(n1 == n2)
        #expect(n1 != baseName)
        #expect(!n1.lowercased().contains("uuid"))
        #expect(n1.hasPrefix(baseName + "-"))
    }
}
