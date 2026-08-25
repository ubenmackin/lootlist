//
//  FamilyServiceTests+Authorization.swift
//  LootList
//
//  Created by Ben Mackin on 8/4/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

extension FamilyServiceTests {
    // MARK: - Service-Layer Authorization & Settings Mutations

    @Test
    func `updateMemberRole throws unauthorized when acting profile is a hero`() async {
        let (familyService, _, appState, _) = makeDependencies()
        let (_, _, _, hero, _) = makeStandardFixtures()

        // Case 1: unauthenticated
        await #expect(throws: FamilyServiceError.unauthorized) {
            try await familyService.updateMemberRole(profile: hero, newRole: .ranger)
        }

        // Case 2: non-parent (hero)
        appState.currentProfile = hero
        await #expect(throws: FamilyServiceError.unauthorized) {
            try await familyService.updateMemberRole(profile: hero, newRole: .ranger)
        }
    }

    @Test
    func `updateMemberRole throws unauthorized when no acting profile exists`() async {
        let (familyService, _, _, _) = makeDependencies()
        let (_, _, _, hero, _) = makeStandardFixtures()

        await #expect(throws: FamilyServiceError.unauthorized) {
            try await familyService.updateMemberRole(profile: hero, newRole: .ranger)
        }
    }

    @Test
    func `kickMember throws unauthorized when acting profile is a hero`() async {
        let (familyService, _, appState, _) = makeDependencies()
        let (_, _, _, hero, _) = makeStandardFixtures()

        // Case 1: unauthenticated
        await #expect(throws: FamilyServiceError.unauthorized) {
            try await familyService.kickMember(profile: hero)
        }

        // Case 2: non-parent (hero)
        appState.currentProfile = hero
        await #expect(throws: FamilyServiceError.unauthorized) {
            try await familyService.kickMember(profile: hero)
        }
    }

    @Test
    func `updateMemberRole succeeds when acting profile is a ranger parent`() async throws {
        let (familyService, cloudKit, appState, _) = makeDependencies()
        let cache = try CacheService(inMemory: true)
        familyService.cacheService = cache

        let (zoneID, familyRef, family, hero, _) = makeStandardFixtures()
        // Rangers are parent roles: they may promote a hero.
        let ranger = Profile(
            displayName: "Ranger",
            role: .ranger,
            iCloudUserID: CKRecord.ID(recordName: "r1", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "ranger1", zoneID: zoneID)
        )
        cache.upsertFamily(family)
        cache.upsertProfile(hero)
        cloudKit.seedMockRecords([family, hero])
        appState.family = family
        appState.currentProfile = ranger

        try await familyService.updateMemberRole(profile: hero, newRole: .ranger)

        let cachedHero = cache.fetchProfiles(family: "fam1").first { $0.recordName == hero.id.recordName }
        #expect(cachedHero?.role == UserRole.ranger.rawValue)
    }

    @Test
    func `updateFamilyName throws unauthorized for non-parent`() async {
        let (familyService, _, appState, _) = makeDependencies()
        let (_, _, family, hero, _) = makeStandardFixtures()

        // Case 1: unauthenticated
        await #expect(throws: FamilyServiceError.unauthorized) {
            try await familyService.updateFamilyName(family: family, newName: "New Name")
        }

        // Case 2: non-parent (hero)
        appState.currentProfile = hero
        await #expect(throws: FamilyServiceError.unauthorized) {
            try await familyService.updateFamilyName(family: family, newName: "New Name")
        }
    }

    @Test
    func `updateFamilyName succeeds when parent`() async throws {
        let (familyService, cloudKit, appState, _) = makeDependencies()
        let cache = try CacheService(inMemory: true)
        familyService.cacheService = cache

        let (_, _, family, _, parent) = makeStandardFixtures()
        cache.upsertFamily(family)
        cloudKit.seedMockRecords([family])
        appState.family = family
        appState.currentProfile = parent

        let updated = try await familyService.updateFamilyName(family: family, newName: "New Guild")
        #expect(updated.name == "New Guild")
    }

    @Test
    func `updatePayoutPolicy throws unauthorized for non-parent`() async {
        let (familyService, _, appState, _) = makeDependencies()
        let (_, _, family, hero, _) = makeStandardFixtures()

        appState.currentProfile = hero
        await #expect(throws: FamilyServiceError.unauthorized) {
            try await familyService.updatePayoutPolicy(family: family, policy: .allOrNothing)
        }
    }

    @Test
    func `updatePayoutPolicy succeeds when parent`() async throws {
        let (familyService, cloudKit, appState, _) = makeDependencies()
        let cache = try CacheService(inMemory: true)
        familyService.cacheService = cache

        let (_, _, family, _, parent) = makeStandardFixtures()
        cache.upsertFamily(family)
        cloudKit.seedMockRecords([family])
        appState.family = family
        appState.currentProfile = parent

        let updated = try await familyService.updatePayoutPolicy(family: family, policy: .allOrNothing)
        #expect(updated.payoutPolicy == PayoutPolicy.allOrNothing)
    }

    @Test
    func `updatePayoutDay throws unauthorized for non-parent`() async {
        let (familyService, _, appState, _) = makeDependencies()
        let (_, _, family, hero, _) = makeStandardFixtures()

        appState.currentProfile = hero
        await #expect(throws: FamilyServiceError.unauthorized) {
            try await familyService.updatePayoutDay(family: family, day: .friday)
        }
    }

    @Test
    func `updatePayoutDay succeeds when parent`() async throws {
        let (familyService, cloudKit, appState, _) = makeDependencies()
        let cache = try CacheService(inMemory: true)
        familyService.cacheService = cache

        let (_, _, family, _, parent) = makeStandardFixtures()
        cache.upsertFamily(family)
        cloudKit.seedMockRecords([family])
        appState.family = family
        appState.currentProfile = parent

        let updated = try await familyService.updatePayoutDay(family: family, day: .friday)
        #expect(updated.payoutDay == PayoutDay.friday)
    }

    @Test
    func `updateProfilePayoutPolicy throws unauthorized for unauthenticated or non-parent non-self hero`() async {
        let (familyService, _, appState, _) = makeDependencies()
        let (zoneID, familyRef, _, hero1, _) = makeStandardFixtures()
        let hero2 = Profile(
            displayName: "Hero 2",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "u2", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "hero2", zoneID: zoneID)
        )

        // Case 1: unauthenticated
        await #expect(throws: FamilyServiceError.unauthorized) {
            try await familyService.updateProfilePayoutPolicy(profile: hero1, policy: .allOrNothing)
        }

        // Case 2: hero2 attempting to change hero1's payout policy
        appState.currentProfile = hero2
        await #expect(throws: FamilyServiceError.unauthorized) {
            try await familyService.updateProfilePayoutPolicy(profile: hero1, policy: .allOrNothing)
        }
    }

    @Test
    func `updateProfilePayoutPolicy succeeds when self or parent`() async throws {
        let (familyService, cloudKit, appState, _) = makeDependencies()
        let cache = try CacheService(inMemory: true)
        familyService.cacheService = cache

        let (_, _, _, hero, parent) = makeStandardFixtures()
        cache.upsertProfile(hero)
        cloudKit.seedMockRecords([hero])

        // Self hero succeeds
        appState.currentProfile = hero
        let savedBySelf = try await familyService.updateProfilePayoutPolicy(profile: hero, policy: .realTime)
        #expect(savedBySelf.payoutPolicy == PayoutPolicy.realTime)

        // Parent succeeds for hero profile
        appState.currentProfile = parent
        let savedByParent = try await familyService.updateProfilePayoutPolicy(profile: hero, policy: .allOrNothing)
        #expect(savedByParent.payoutPolicy == PayoutPolicy.allOrNothing)

        // Parent resets to Guild Default (nil)
        let resetToDefault = try await familyService.updateProfilePayoutPolicy(profile: hero, policy: nil)
        #expect(resetToDefault.payoutPolicy == nil)
        #expect(cache.fetchProfiles(family: hero.family.recordID.recordName).first { $0.recordName == hero.id.recordName }?.payoutPolicyEnum == nil)
    }

    @Test
    func `updateProfilePayoutDay throws unauthorized for non-parent non-self hero`() async {
        let (familyService, _, appState, _) = makeDependencies()
        let (zoneID, familyRef, _, hero1, _) = makeStandardFixtures()
        let hero2 = Profile(
            displayName: "Hero 2",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "u2", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "hero2", zoneID: zoneID)
        )

        appState.currentProfile = hero2
        await #expect(throws: FamilyServiceError.unauthorized) {
            try await familyService.updateProfilePayoutDay(profile: hero1, day: .friday)
        }
    }

    @Test
    func `updateProfilePayoutDay succeeds when self or parent`() async throws {
        let (familyService, cloudKit, appState, _) = makeDependencies()
        let cache = try CacheService(inMemory: true)
        familyService.cacheService = cache

        let (_, _, _, hero, parent) = makeStandardFixtures()
        cache.upsertProfile(hero)
        cloudKit.seedMockRecords([hero])

        // Self hero
        appState.currentProfile = hero
        let savedBySelf = try await familyService.updateProfilePayoutDay(profile: hero, day: .saturday)
        #expect(savedBySelf.payoutDay == PayoutDay.saturday)

        // Parent
        appState.currentProfile = parent
        let savedByParent = try await familyService.updateProfilePayoutDay(profile: hero, day: .friday)
        #expect(savedByParent.payoutDay == PayoutDay.friday)
    }

    @Test
    func `deleteFamilyAndReset throws unauthorized when not parent or not zone owner`() async {
        let (familyService, cloudKit, appState, _) = makeDependencies()
        let (_, _, family, hero, parent) = makeStandardFixtures()
        appState.family = family
        appState.familyZoneID = family.id.zoneID
        cloudKit.activeFamilyZoneID = family.id.zoneID

        // Case 1: Hero acting, zone owner true
        appState.isZoneOwner = true
        cloudKit.activeIsOwner = true
        appState.currentProfile = hero
        await #expect(throws: FamilyServiceError.unauthorized) {
            try await familyService.deleteFamilyAndReset(family: family)
        }

        // Case 2: Parent acting, zone owner false
        appState.isZoneOwner = false
        cloudKit.activeIsOwner = false
        appState.currentProfile = parent
        await #expect(throws: FamilyServiceError.unauthorized) {
            try await familyService.deleteFamilyAndReset(family: family)
        }
    }

    @Test
    func `deleteFamilyAndReset succeeds when parent and zone owner`() async throws {
        let (familyService, _, appState, _) = makeDependencies()
        let (zoneID, _, family, _, parent) = makeStandardFixtures()

        appState.family = family
        appState.familyZoneID = zoneID
        appState.isZoneOwner = true
        appState.currentProfile = parent

        try await familyService.deleteFamilyAndReset(family: family)
        #expect(appState.currentProfile == nil)
    }

    @Test
    func `updateProfileDisplayName throws unauthorized for non-self`() async {
        let (familyService, _, appState, _) = makeDependencies()
        let (zoneID, familyRef, _, hero1, _) = makeStandardFixtures()
        let hero2 = Profile(
            displayName: "Hero 2",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "u2", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "hero2", zoneID: zoneID)
        )

        // hero2 attempting to change hero1's name
        appState.currentProfile = hero2
        await #expect(throws: FamilyServiceError.unauthorized) {
            try await familyService.updateProfileDisplayName(profile: hero1, newName: "New Name")
        }
    }

    @Test
    func `updateProfileDisplayName succeeds when self`() async throws {
        let (familyService, cloudKit, appState, _) = makeDependencies()
        let cache = try CacheService(inMemory: true)
        familyService.cacheService = cache

        let (_, _, _, hero, _) = makeStandardFixtures()
        cache.upsertProfile(hero)
        cloudKit.seedMockRecords([hero])
        appState.currentProfile = hero

        let updated = try await familyService.updateProfileDisplayName(profile: hero, newName: "New Name")
        #expect(updated.displayName == "New Name")
    }

    @Test
    func `updateProfileAvatar throws unauthorized for non-self`() async {
        let (familyService, _, appState, _) = makeDependencies()
        let (zoneID, familyRef, _, hero1, _) = makeStandardFixtures()
        let hero2 = Profile(
            displayName: "Hero 2",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "u2", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "hero2", zoneID: zoneID)
        )

        appState.currentProfile = hero2
        await #expect(throws: FamilyServiceError.unauthorized) {
            try await familyService.updateProfileAvatar(profile: hero1, avatarClass: .mage, avatarPresetID: "mage_01", customAvatarImageData: nil)
        }
    }

    @Test
    func `updateProfileAvatar succeeds when self`() async throws {
        let (familyService, cloudKit, appState, _) = makeDependencies()
        let cache = try CacheService(inMemory: true)
        familyService.cacheService = cache

        let (_, _, _, hero, _) = makeStandardFixtures()
        cache.upsertProfile(hero)
        cloudKit.seedMockRecords([hero])
        appState.currentProfile = hero

        let updated = try await familyService.updateProfileAvatar(profile: hero, avatarClass: .mage, avatarPresetID: "mage_01", customAvatarImageData: nil)
        #expect(updated.avatarClass == AvatarClass.mage)
        #expect(updated.avatarPresetID == "mage_01")
    }

    // MARK: - Owner Anchor Authorization

    /// The mock's fixed server-authenticated iCloud user
    /// (`MockCloudKitService.currentUserRecordID`) — the identity every
    /// emulated server `save` stamps as a record's creator.
    private static let mockOwner = MockCloudKitService.mockUserRecordName

    @Test
    func `createFamily round-trips the server-stamped creator through the mock`() async throws {
        let (familyService, _, _, _) = makeDependencies()
        let (_, familyRef, _, _, _) = makeStandardFixtures()
        let ownerProfile = Profile(
            displayName: "Founding GM",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "u1"),
            family: familyRef
        )

        let result = try await familyService.createFamily(name: "Anchored Guild", ownerProfile: ownerProfile)

        // The mock's `save` emulates the server: it stamps the acting user
        // ("mockUser") as the family's creator and re-decodes the record, so the
        // returned family carries the server-authenticated creator anchor.
        #expect(result.family.creatorUserRecordName == Self.mockOwner)
    }

    @Test
    func `fetch applies the mock's server-stamped creator`() async throws {
        let (zoneID, _, family, _, _) = makeStandardFixtures()
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        cloudKit.seedMockRecords([family], creatorUserRecordName: Self.mockOwner)

        let fetched = try await cloudKit.fetch(Family.self, id: family.id)

        // The seeded `Family` never authored the creator locally — the mock's
        // server-stamp registry supplies it on the read path.
        #expect(fetched.creatorUserRecordName == Self.mockOwner)
    }

    @Test
    func `deleteFamilyAndReset throws unauthorized when mock-stamped creator is not the acting user`() async throws {
        let (familyService, cloudKit, appState, _) = makeDependencies()
        let (_, _, family, _, _) = makeStandardFixtures()
        // The real (mock) identity is "mockUser"; the family's server-stamped
        // creator is a DIFFERENT iCloud user, so the forged role field cannot
        // grant the irreversible delete.
        cloudKit.seedMockRecords([family], creatorUserRecordName: "someoneElse")
        let anchoredFamily = try await cloudKit.fetch(Family.self, id: family.id)
        appState.family = anchoredFamily
        appState.familyZoneID = anchoredFamily.id.zoneID
        appState.isZoneOwner = true
        cloudKit.activeFamilyZoneID = anchoredFamily.id.zoneID
        cloudKit.activeIsOwner = true
        appState.currentProfile = nil

        await #expect(throws: FamilyServiceError.unauthorized) {
            try await familyService.deleteFamilyAndReset(family: anchoredFamily)
        }
    }

    @Test
    func `deleteFamilyAndReset succeeds when mock-stamped creator matches the acting user`() async throws {
        let (familyService, cloudKit, appState, _) = makeDependencies()
        let (zoneID, _, family, _, _) = makeStandardFixtures()
        // Creator stamped by the mock as the mock's current user ("mockUser"),
        // so owner-gated delete is authorized.
        cloudKit.seedMockRecords([family], creatorUserRecordName: Self.mockOwner)
        let anchoredFamily = try await cloudKit.fetch(Family.self, id: family.id)
        appState.family = anchoredFamily
        appState.familyZoneID = zoneID
        appState.isZoneOwner = true
        appState.currentProfile = nil

        try await familyService.deleteFamilyAndReset(family: anchoredFamily)
        #expect(appState.currentProfile == nil)
    }

    @Test
    func `updateMemberRole throws unauthorized when mock-stamped creator is not the acting user`() async throws {
        let (familyService, cloudKit, appState, _) = makeDependencies()
        let cache = try CacheService(inMemory: true)
        familyService.cacheService = cache

        let (zoneID, familyRef, family, hero, _) = makeStandardFixtures()
        // The family is mocked — NOT cached — so `family(for:)` reads CloudKit
        // and sees the server stamp of a DIFFERENT iCloud user than the acting
        // "mockUser" identity.
        cloudKit.seedMockRecords([family, hero], creatorUserRecordName: "someoneElse")
        let forgedGM = Profile(
            displayName: "Forged GM",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "forged", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "forged-gm", zoneID: zoneID)
        )
        appState.family = family
        appState.currentProfile = forgedGM

        await #expect(throws: FamilyServiceError.unauthorized) {
            try await familyService.updateMemberRole(profile: hero, newRole: .ranger)
        }
    }

    @Test
    func `updateMemberRole succeeds when mock-stamped creator matches the acting user`() async throws {
        let (familyService, cloudKit, appState, _) = makeDependencies()
        let cache = try CacheService(inMemory: true)
        familyService.cacheService = cache

        let (zoneID, familyRef, family, hero, _) = makeStandardFixtures()
        // Creator stamped by the mock as the mock's current user ("mockUser"),
        // so the owner anchor authorizes the role change.
        cloudKit.seedMockRecords([family, hero], creatorUserRecordName: Self.mockOwner)
        let owner = Profile(
            displayName: "Owner",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "owner", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "owner-gm", zoneID: zoneID)
        )
        appState.family = family
        appState.currentProfile = owner

        try await familyService.updateMemberRole(profile: hero, newRole: .ranger)

        let cachedHero = cache.fetchProfiles(family: "fam1").first { $0.recordName == hero.id.recordName }
        #expect(cachedHero?.role == UserRole.ranger.rawValue)
    }

    @Test
    func `kickMember throws unauthorized when mock-stamped creator is not the acting user`() async throws {
        let (familyService, cloudKit, appState, _) = makeDependencies()
        let cache = try CacheService(inMemory: true)
        familyService.cacheService = cache

        let (zoneID, familyRef, family, hero, _) = makeStandardFixtures()
        // Anchor set to "someoneElse" — not the current acting user ("mockUser").
        cloudKit.seedMockRecords([family, hero], creatorUserRecordName: "someoneElse")
        let attacker = Profile(
            displayName: "Pretender GM",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "attacker", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "attacker", zoneID: zoneID)
        )
        appState.family = family
        appState.currentProfile = attacker

        await #expect(throws: FamilyServiceError.unauthorized) {
            try await familyService.kickMember(profile: hero)
        }
    }

    @Test
    func `kickMember succeeds when mock-stamped creator matches the acting user`() async throws {
        let (familyService, cloudKit, appState, _) = makeDependencies()
        let cache = try CacheService(inMemory: true)
        familyService.cacheService = cache

        let (zoneID, familyRef, family, hero, _) = makeStandardFixtures()
        cloudKit.seedMockRecords([family, hero], creatorUserRecordName: Self.mockOwner)
        let owner = Profile(
            displayName: "True GM",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "owner", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "owner-gm", zoneID: zoneID)
        )
        appState.family = family
        appState.currentProfile = owner

        try await familyService.kickMember(profile: hero)
        let cachedHero = cache.fetchProfiles(family: "fam1").first { $0.recordName == hero.id.recordName }
        #expect(cachedHero?.isActive == false)
    }

    @Test
    func `updateMemberRole legacy nil-creator falls back to parent role`() async throws {
        let (familyService, cloudKit, appState, _) = makeDependencies()
        let cache = try CacheService(inMemory: true)
        familyService.cacheService = cache

        let (zoneID, familyRef, family, hero, _) = makeStandardFixtures()
        cache.upsertProfile(hero)
        cloudKit.seedMockRecords([family, hero], creatorUserRecordName: nil)
        let parent = Profile(
            displayName: "Guild Master",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "gm1", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "gm1", zoneID: zoneID)
        )
        appState.family = family
        appState.currentProfile = parent

        try await familyService.updateMemberRole(profile: hero, newRole: .ranger)
        let cachedHero = cache.fetchProfiles(family: "fam1").first { $0.recordName == hero.id.recordName }
        #expect(cachedHero?.role == UserRole.ranger.rawValue)
    }
}
