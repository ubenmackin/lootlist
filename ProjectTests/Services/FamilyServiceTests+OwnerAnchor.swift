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
        let deps = makeDependencies()
        let cache = try CacheService(inMemory: true)
        deps.familyService.cacheService = cache

        // Anchor the family to the mock's current iCloud user, then fetch it
        // back so the server-stamped creator round-trips onto the struct.
        let fixtures = makeStandardFixtures()
        deps.cloudKit.seedMockRecords([fixtures.family], creatorUserRecordName: Self.mockUserRecordName)
        let anchoredFamily = try await deps.cloudKit.fetch(Family.self, id: fixtures.family.id)
        #expect(anchoredFamily.creatorUserRecordName == Self.mockUserRecordName)

        await cache.upsertFamily(anchoredFamily)
        deps.appState.family = anchoredFamily
        // The acting profile is a HERO — a non-parent role. Only the owner
        // anchor (server-authenticated creator match) can authorize this.
        deps.appState.currentProfile = fixtures.hero

        let updated = try await deps.familyService.updateFamilyName(family: anchoredFamily, newName: "Anchored Guild")
        #expect(updated.name == "Anchored Guild")
    }

    @Test
    func `updatePayoutPolicy succeeds when owner anchor grants a hero actor`() async throws {
        let deps = makeDependencies()
        let cache = try CacheService(inMemory: true)
        deps.familyService.cacheService = cache

        let fixtures = makeStandardFixtures()
        deps.cloudKit.seedMockRecords([fixtures.family], creatorUserRecordName: Self.mockUserRecordName)
        let anchoredFamily = try await deps.cloudKit.fetch(Family.self, id: fixtures.family.id)
        await cache.upsertFamily(anchoredFamily)
        deps.appState.family = anchoredFamily
        deps.appState.currentProfile = fixtures.hero

        let updated = try await deps.familyService.updatePayoutPolicy(family: anchoredFamily, policy: .allOrNothing)
        #expect(updated.payoutPolicy == .allOrNothing)
    }

    @Test
    func `updatePayoutDay succeeds when family is anchored to the acting user`() async throws {
        let deps = makeDependencies()
        let cache = try CacheService(inMemory: true)
        deps.familyService.cacheService = cache

        let fixtures = makeStandardFixtures()
        deps.cloudKit.seedMockRecords([fixtures.family], creatorUserRecordName: Self.mockUserRecordName)
        let anchoredFamily = try await deps.cloudKit.fetch(Family.self, id: fixtures.family.id)
        await cache.upsertFamily(anchoredFamily)
        deps.appState.family = anchoredFamily
        deps.appState.currentProfile = fixtures.hero

        let updated = try await deps.familyService.updatePayoutDay(family: anchoredFamily, day: .friday)
        #expect(updated.payoutDay == .friday)
    }

    // MARK: - Unauthorized (Non-Parent, Non-Owner) Family Settings Path

    @Test
    func `updateFamilyName throws unauthorized for a hero who is not the owner anchor`() async {
        let deps = makeDependencies()
        let fixtures = makeStandardFixtures()
        // The family's server stamp points at a DIFFERENT iCloud user than the
        // acting identity, so neither the parent-role check nor the owner
        // anchor authorizes the mutation.
        deps.cloudKit.seedMockRecords([fixtures.family], creatorUserRecordName: "someoneElse")
        let anchoredFamily = try? await deps.cloudKit.fetch(Family.self, id: fixtures.family.id)
        deps.appState.currentProfile = fixtures.hero

        await #expect(throws: FamilyServiceError.unauthorized) {
            _ = try await deps.familyService.updateFamilyName(family: anchoredFamily ?? fixtures.family, newName: "Hijacked Guild")
        }
    }

    @Test
    func `updatePayoutPolicy throws unauthorized for a hero who is not the owner anchor`() async {
        let deps = makeDependencies()
        let fixtures = makeStandardFixtures()
        deps.cloudKit.seedMockRecords([fixtures.family], creatorUserRecordName: "someoneElse")
        let anchoredFamily = try? await deps.cloudKit.fetch(Family.self, id: fixtures.family.id)
        deps.appState.currentProfile = fixtures.hero

        await #expect(throws: FamilyServiceError.unauthorized) {
            _ = try await deps.familyService.updatePayoutPolicy(family: anchoredFamily ?? fixtures.family, policy: .allOrNothing)
        }
    }

    @Test
    func `updatePayoutDay throws unauthorized for a hero who is not the owner anchor`() async {
        let deps = makeDependencies()
        let fixtures = makeStandardFixtures()
        deps.cloudKit.seedMockRecords([fixtures.family], creatorUserRecordName: "someoneElse")
        let anchoredFamily = try? await deps.cloudKit.fetch(Family.self, id: fixtures.family.id)
        deps.appState.currentProfile = fixtures.hero

        await #expect(throws: FamilyServiceError.unauthorized) {
            _ = try await deps.familyService.updatePayoutDay(family: anchoredFamily ?? fixtures.family, day: .friday)
        }
    }

    // MARK: - Deposit / Withdraw Unauthorized (Non-Parent Actor)

    @Test
    func `deposit throws unauthorized when the actor is a non-parent hero`() async throws {
        let deps = makeDependencies()
        let cache = try CacheService(inMemory: true)
        let spending = SpendingService(cloudKit: deps.cloudKit, cacheService: cache, appState: deps.appState)

        let fixtures = makeStandardFixtures()
        deps.appState.currentProfile = fixtures.hero

        do {
            _ = try await spending.depositEntries(
                profile: fixtures.hero,
                family: fixtures.family,
                familyRecordName: fixtures.family.id.recordName,
                description: "Gift from Grandpa",
                amount: 2500
            )
            #expect(Bool(false), "Expected unauthorized")
        } catch {
            #expect((error as? FamilyServiceError) == .unauthorized)
        }

        // The rejected deposit must not write a ledger entry.
        let cached = cache.fetchLedgerEntries(profileRecordName: fixtures.hero.id.recordName, family: fixtures.family.id.recordName)
        #expect(cached.isEmpty)
    }

    @Test
    func `withdraw throws unauthorized when the actor is a non-parent hero`() async throws {
        let deps = makeDependencies()
        let cache = try CacheService(inMemory: true)
        let spending = SpendingService(cloudKit: deps.cloudKit, cacheService: cache, appState: deps.appState)

        let fixtures = makeStandardFixtures()
        deps.appState.currentProfile = fixtures.hero

        do {
            _ = try await spending.withdraw(
                profile: fixtures.hero,
                family: fixtures.family,
                familyRecordName: fixtures.family.id.recordName,
                description: "Camp cash",
                amount: 1000
            )
            #expect(Bool(false), "Expected unauthorized")
        } catch {
            #expect((error as? FamilyServiceError) == .unauthorized)
        }

        // The rejected withdraw must not write a ledger entry.
        let cached = cache.fetchLedgerEntries(profileRecordName: fixtures.hero.id.recordName, family: fixtures.family.id.recordName)
        #expect(cached.isEmpty)
    }
}
