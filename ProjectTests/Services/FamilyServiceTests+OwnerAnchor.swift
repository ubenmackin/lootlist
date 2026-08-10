//
//  FamilyServiceTests+OwnerAnchor.swift
//  LootList
//
//  Created by Ben Mackin on 8/8/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

extension FamilyServiceTests {
    // MARK: - Owner-Anchor Grant (Reversible Family Settings)

    /// The mock's fixed server-authenticated iCloud user
    /// (`MockCloudKitService.currentUserRecordID`) — the identity every
    /// emulated server `save` stamps as a record's creator.
    private static let mockUserRecordName = MockCloudKitService.mockUserRecordName

    @Test
    func `updateFamilyName succeeds when a non-parent hero is the owner anchor`() async throws {
        let (familyService, cloudKit, appState, _) = makeDependencies()
        let cache = try CacheService(inMemory: true)
        familyService.cacheService = cache

        // Anchor the family to the mock's current iCloud user, then fetch it
        // back so the server-stamped creator round-trips onto the struct.
        let (_, _, family, hero, _) = makeStandardFixtures()
        cloudKit.seedMockRecords([family], creatorUserRecordName: Self.mockUserRecordName)
        let anchoredFamily = try await cloudKit.fetch(Family.self, id: family.id)
        #expect(anchoredFamily.creatorUserRecordName == Self.mockUserRecordName)

        cache.upsertFamily(anchoredFamily)
        appState.family = anchoredFamily
        // The acting profile is a HERO — a non-parent role. Only the owner
        // anchor (server-authenticated creator match) can authorize this.
        appState.currentProfile = hero

        let updated = try await familyService.updateFamilyName(family: anchoredFamily, newName: "Anchored Guild")
        #expect(updated.name == "Anchored Guild")
    }

    @Test
    func `updatePayoutPolicy succeeds when owner anchor grants a hero actor`() async throws {
        let (familyService, cloudKit, appState, _) = makeDependencies()
        let cache = try CacheService(inMemory: true)
        familyService.cacheService = cache

        let (_, _, family, hero, _) = makeStandardFixtures()
        cloudKit.seedMockRecords([family], creatorUserRecordName: Self.mockUserRecordName)
        let anchoredFamily = try await cloudKit.fetch(Family.self, id: family.id)
        cache.upsertFamily(anchoredFamily)
        appState.family = anchoredFamily
        appState.currentProfile = hero

        let updated = try await familyService.updatePayoutPolicy(family: anchoredFamily, policy: .allOrNothing)
        #expect(updated.payoutPolicy == .allOrNothing)
    }

    @Test
    func `updatePayoutDay succeeds when family is anchored to the acting user`() async throws {
        let (familyService, cloudKit, appState, _) = makeDependencies()
        let cache = try CacheService(inMemory: true)
        familyService.cacheService = cache

        let (_, _, family, hero, _) = makeStandardFixtures()
        cloudKit.seedMockRecords([family], creatorUserRecordName: Self.mockUserRecordName)
        let anchoredFamily = try await cloudKit.fetch(Family.self, id: family.id)
        cache.upsertFamily(anchoredFamily)
        appState.family = anchoredFamily
        appState.currentProfile = hero

        let updated = try await familyService.updatePayoutDay(family: anchoredFamily, day: .friday)
        #expect(updated.payoutDay == .friday)
    }

    // MARK: - Unauthorized (Non-Parent, Non-Owner) Family Settings Path

    @Test
    func `updateFamilyName throws unauthorized for a hero who is not the owner anchor`() async {
        let (familyService, cloudKit, appState, _) = makeDependencies()
        let (_, _, family, hero, _) = makeStandardFixtures()
        // The family's server stamp points at a DIFFERENT iCloud user than the
        // acting identity, so neither the parent-role check nor the owner
        // anchor authorizes the mutation.
        cloudKit.seedMockRecords([family], creatorUserRecordName: "someoneElse")
        let anchoredFamily = try? await cloudKit.fetch(Family.self, id: family.id)
        appState.currentProfile = hero

        await #expect(throws: FamilyServiceError.unauthorized) {
            _ = try await familyService.updateFamilyName(family: anchoredFamily ?? family, newName: "Hijacked Guild")
        }
    }

    @Test
    func `updatePayoutPolicy throws unauthorized for a hero who is not the owner anchor`() async {
        let (familyService, cloudKit, appState, _) = makeDependencies()
        let (_, _, family, hero, _) = makeStandardFixtures()
        cloudKit.seedMockRecords([family], creatorUserRecordName: "someoneElse")
        let anchoredFamily = try? await cloudKit.fetch(Family.self, id: family.id)
        appState.currentProfile = hero

        await #expect(throws: FamilyServiceError.unauthorized) {
            _ = try await familyService.updatePayoutPolicy(family: anchoredFamily ?? family, policy: .allOrNothing)
        }
    }

    @Test
    func `updatePayoutDay throws unauthorized for a hero who is not the owner anchor`() async {
        let (familyService, cloudKit, appState, _) = makeDependencies()
        let (_, _, family, hero, _) = makeStandardFixtures()
        cloudKit.seedMockRecords([family], creatorUserRecordName: "someoneElse")
        let anchoredFamily = try? await cloudKit.fetch(Family.self, id: family.id)
        appState.currentProfile = hero

        await #expect(throws: FamilyServiceError.unauthorized) {
            _ = try await familyService.updatePayoutDay(family: anchoredFamily ?? family, day: .friday)
        }
    }

    // MARK: - Deposit / Withdraw Unauthorized (Non-Parent Actor)

    @Test
    func `deposit throws unauthorized when the actor is a non-parent hero`() async throws {
        let (_, cloudKit, appState, _) = makeDependencies()
        let cache = try CacheService(inMemory: true)
        let spending = ManualSpendingService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let (_, _, family, hero, _) = makeStandardFixtures()
        appState.currentProfile = hero

        do {
            _ = try await spending.deposit(
                profile: hero,
                family: family,
                familyRecordName: family.id.recordName,
                description: "Gift from Grandpa",
                amount: 25.0
            )
            #expect(Bool(false), "Expected unauthorized")
        } catch {
            #expect((error as? FamilyServiceError) == .unauthorized)
        }

        // The rejected deposit must not write a ledger entry.
        let cached = cache.fetchLedgerEntries(profileRecordName: hero.id.recordName)
        #expect(cached.isEmpty)
    }

    @Test
    func `withdraw throws unauthorized when the actor is a non-parent hero`() async throws {
        let (_, cloudKit, appState, _) = makeDependencies()
        let cache = try CacheService(inMemory: true)
        let spending = ManualSpendingService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let (_, _, family, hero, _) = makeStandardFixtures()
        appState.currentProfile = hero

        do {
            _ = try await spending.withdraw(
                profile: hero,
                family: family,
                familyRecordName: family.id.recordName,
                description: "Camp cash",
                amount: 10.0
            )
            #expect(Bool(false), "Expected unauthorized")
        } catch {
            #expect((error as? FamilyServiceError) == .unauthorized)
        }

        // The rejected withdraw must not write a ledger entry.
        let cached = cache.fetchLedgerEntries(profileRecordName: hero.id.recordName)
        #expect(cached.isEmpty)
    }
}
