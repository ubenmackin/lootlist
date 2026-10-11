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
        let deps = makeDependencies()
        let fixtures = makeStandardFixtures()
        // WHY resolved non-owner anchor: denial must come from the owner check, not a missing family.
        deps.cloudKit.seedMockRecords([fixtures.family], creatorUserRecordName: "someoneElse")

        // Case 1: unauthenticated
        await #expect(throws: FamilyServiceError.unauthorized) {
            try await deps.familyService.updateMemberRole(profile: fixtures.hero, newRole: .ranger)
        }

        // Case 2: non-parent (hero)
        deps.appState.currentProfile = fixtures.hero
        await #expect(throws: FamilyServiceError.unauthorized) {
            try await deps.familyService.updateMemberRole(profile: fixtures.hero, newRole: .ranger)
        }
    }

    @Test
    func `updateMemberRole throws unauthorized when no acting profile exists`() async {
        let deps = makeDependencies()
        let fixtures = makeStandardFixtures()
        // WHY resolved non-owner anchor: denial must come from the owner check, not a missing family.
        deps.cloudKit.seedMockRecords([fixtures.family], creatorUserRecordName: "someoneElse")

        await #expect(throws: FamilyServiceError.unauthorized) {
            try await deps.familyService.updateMemberRole(profile: fixtures.hero, newRole: .ranger)
        }
    }

    @Test
    func `kickMember throws unauthorized when acting profile is a hero`() async {
        let deps = makeDependencies()
        let fixtures = makeStandardFixtures()
        // WHY resolved non-owner anchor: denial must come from the owner check, not a missing family.
        deps.cloudKit.seedMockRecords([fixtures.family], creatorUserRecordName: "someoneElse")

        // Case 1: unauthenticated
        await #expect(throws: FamilyServiceError.unauthorized) {
            try await deps.familyService.kickMember(profile: fixtures.hero)
        }

        // Case 2: non-parent (hero)
        deps.appState.currentProfile = fixtures.hero
        await #expect(throws: FamilyServiceError.unauthorized) {
            try await deps.familyService.kickMember(profile: fixtures.hero)
        }
    }

    @Test
    func `updateMemberRole succeeds via owner-device anchor for acting owner`() async throws {
        let deps = makeDependencies()
        let cache = try CacheService(inMemory: true)
        deps.familyService.cacheService = cache

        let fixtures = makeStandardFixtures()
        // WHY owner-device authorizes: irreversible role change anchors on server-authenticated device, not acting role.
        let owner = Profile(
            displayName: "Owner",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: Self.mockOwner, zoneID: fixtures.zoneID),
            family: fixtures.familyRef,
            id: CKRecord.ID(recordName: "owner1", zoneID: fixtures.zoneID)
        )
        await cache.upsertFamily(fixtures.family)
        await cache.upsertProfile(fixtures.hero)
        deps.cloudKit.seedMockRecords([fixtures.family, fixtures.hero], creatorUserRecordName: Self.mockOwner)
        deps.appState.family = fixtures.family
        deps.appState.currentProfile = owner

        try await deps.familyService.updateMemberRole(profile: fixtures.hero, newRole: .ranger)

        let cachedHero = cache.fetchProfiles(family: "fam1").first { $0.recordName == fixtures.hero.id.recordName }
        #expect(cachedHero?.role == UserRole.ranger.rawValue)
    }

    @Test
    func `updateMemberRole throws unauthorized for ranger without owner-device anchor`() async throws {
        let deps = makeDependencies()
        let cache = try CacheService(inMemory: true)
        deps.familyService.cacheService = cache

        let fixtures = makeStandardFixtures()
        // WHY owner-only denies: ranger role alone cannot authorize without matching server-stamped creator.
        let ranger = Profile(
            displayName: "Ranger",
            role: .ranger,
            iCloudUserID: CKRecord.ID(recordName: "r1", zoneID: fixtures.zoneID),
            family: fixtures.familyRef,
            id: CKRecord.ID(recordName: "ranger1", zoneID: fixtures.zoneID)
        )
        await cache.upsertProfile(fixtures.hero)
        deps.cloudKit.seedMockRecords([fixtures.family, fixtures.hero], creatorUserRecordName: "someoneElse")
        let anchoredFamily = try await deps.cloudKit.fetch(Family.self, id: fixtures.family.id)
        await cache.upsertFamily(anchoredFamily)
        deps.appState.family = anchoredFamily
        deps.appState.currentProfile = ranger

        await #expect(throws: FamilyServiceError.unauthorized) {
            try await deps.familyService.updateMemberRole(profile: fixtures.hero, newRole: .ranger)
        }
    }

    @Test
    func `updateFamilyName throws unauthorized for non-parent`() async throws {
        let deps = makeDependencies()
        let fixtures = makeStandardFixtures()
        // WHY resolved non-owner anchor: denial must come from the owner check, not legacy nil fallback.
        deps.cloudKit.seedMockRecords([fixtures.family], creatorUserRecordName: "someoneElse")
        let anchoredFamily = try await deps.cloudKit.fetch(Family.self, id: fixtures.family.id)
        deps.appState.family = anchoredFamily
        deps.appState.familyZoneID = anchoredFamily.id.zoneID
        deps.cloudKit.activeFamilyZoneID = anchoredFamily.id.zoneID

        // Case 1: unauthenticated
        await #expect(throws: FamilyServiceError.unauthorized) {
            try await deps.familyService.updateFamilyName(family: anchoredFamily, newName: "New Name")
        }

        // Case 2: non-parent (hero)
        deps.appState.currentProfile = fixtures.hero
        await #expect(throws: FamilyServiceError.unauthorized) {
            try await deps.familyService.updateFamilyName(family: anchoredFamily, newName: "New Name")
        }
    }

    @Test
    func `updateFamilyName succeeds when parent`() async throws {
        let deps = makeDependencies()
        let cache = try CacheService(inMemory: true)
        deps.familyService.cacheService = cache

        let fixtures = makeStandardFixtures()
        await cache.upsertFamily(fixtures.family)
        deps.cloudKit.seedMockRecords([fixtures.family], creatorUserRecordName: Self.mockOwner)
        deps.appState.family = fixtures.family
        deps.appState.currentProfile = fixtures.parent

        let updated = try await deps.familyService.updateFamilyName(family: fixtures.family, newName: "New Guild")
        #expect(updated.name == "New Guild")
    }

    @Test
    func `updatePayoutPolicy throws unauthorized for non-parent`() async throws {
        let deps = makeDependencies()
        let fixtures = makeStandardFixtures()
        // WHY resolved non-owner anchor: denial must come from the owner check, not legacy nil fallback.
        deps.cloudKit.seedMockRecords([fixtures.family], creatorUserRecordName: "someoneElse")
        let anchoredFamily = try await deps.cloudKit.fetch(Family.self, id: fixtures.family.id)
        deps.appState.family = anchoredFamily
        deps.appState.familyZoneID = anchoredFamily.id.zoneID
        deps.cloudKit.activeFamilyZoneID = anchoredFamily.id.zoneID

        deps.appState.currentProfile = fixtures.hero
        await #expect(throws: FamilyServiceError.unauthorized) {
            try await deps.familyService.updatePayoutPolicy(family: anchoredFamily, policy: .allOrNothing)
        }
    }

    @Test
    func `updatePayoutPolicy succeeds when parent`() async throws {
        let deps = makeDependencies()
        let cache = try CacheService(inMemory: true)
        deps.familyService.cacheService = cache

        let fixtures = makeStandardFixtures()
        await cache.upsertFamily(fixtures.family)
        deps.cloudKit.seedMockRecords([fixtures.family], creatorUserRecordName: Self.mockOwner)
        deps.appState.family = fixtures.family
        deps.appState.currentProfile = fixtures.parent

        let updated = try await deps.familyService.updatePayoutPolicy(family: fixtures.family, policy: .allOrNothing)
        #expect(updated.payoutPolicy == PayoutPolicy.allOrNothing)
    }

    @Test
    func `updatePayoutDay throws unauthorized for non-parent`() async throws {
        let deps = makeDependencies()
        let fixtures = makeStandardFixtures()
        // WHY resolved non-owner anchor: denial must come from the owner check, not legacy nil fallback.
        deps.cloudKit.seedMockRecords([fixtures.family], creatorUserRecordName: "someoneElse")
        let anchoredFamily = try await deps.cloudKit.fetch(Family.self, id: fixtures.family.id)
        deps.appState.family = anchoredFamily
        deps.appState.familyZoneID = anchoredFamily.id.zoneID
        deps.cloudKit.activeFamilyZoneID = anchoredFamily.id.zoneID

        deps.appState.currentProfile = fixtures.hero
        await #expect(throws: FamilyServiceError.unauthorized) {
            try await deps.familyService.updatePayoutDay(family: anchoredFamily, day: .friday)
        }
    }

    @Test
    func `updatePayoutDay succeeds when parent`() async throws {
        let deps = makeDependencies()
        let cache = try CacheService(inMemory: true)
        deps.familyService.cacheService = cache

        let fixtures = makeStandardFixtures()
        await cache.upsertFamily(fixtures.family)
        deps.cloudKit.seedMockRecords([fixtures.family], creatorUserRecordName: Self.mockOwner)
        deps.appState.family = fixtures.family
        deps.appState.currentProfile = fixtures.parent

        let updated = try await deps.familyService.updatePayoutDay(family: fixtures.family, day: .friday)
        #expect(updated.payoutDay == PayoutDay.friday)
    }

    @Test
    func `updateProfilePayoutPolicy throws unauthorized for unauthenticated or non-parent non-self hero`() async {
        let deps = makeDependencies()
        let fixtures = makeStandardFixtures()
        let hero2 = Profile(
            displayName: "Hero 2",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "u2", zoneID: fixtures.zoneID),
            family: fixtures.familyRef,
            id: CKRecord.ID(recordName: "hero2", zoneID: fixtures.zoneID)
        )

        // Case 1: unauthenticated
        await #expect(throws: FamilyServiceError.unauthorized) {
            try await deps.familyService.updateProfilePayoutPolicy(profile: fixtures.hero, policy: .allOrNothing)
        }

        // Case 2: hero2 attempting to change hero1's payout policy
        deps.appState.currentProfile = hero2
        await #expect(throws: FamilyServiceError.unauthorized) {
            try await deps.familyService.updateProfilePayoutPolicy(profile: fixtures.hero, policy: .allOrNothing)
        }
    }

    @Test
    func `updateProfilePayoutPolicy succeeds when self or parent`() async throws {
        let deps = makeDependencies()
        let cache = try CacheService(inMemory: true)
        deps.familyService.cacheService = cache

        let fixtures = makeStandardFixtures()
        await cache.upsertProfile(fixtures.hero)
        deps.cloudKit.seedMockRecords([fixtures.hero])

        // Self hero succeeds
        deps.appState.currentProfile = fixtures.hero
        let savedBySelf = try await deps.familyService.updateProfilePayoutPolicy(profile: fixtures.hero, policy: .realTime)
        #expect(savedBySelf.payoutPolicy == PayoutPolicy.realTime)

        // Parent succeeds for hero profile
        deps.appState.currentProfile = fixtures.parent
        let savedByParent = try await deps.familyService.updateProfilePayoutPolicy(profile: fixtures.hero, policy: .allOrNothing)
        #expect(savedByParent.payoutPolicy == PayoutPolicy.allOrNothing)

        // Parent resets to Guild Default (nil)
        let resetToDefault = try await deps.familyService.updateProfilePayoutPolicy(profile: fixtures.hero, policy: nil)
        #expect(resetToDefault.payoutPolicy == nil)
        #expect(cache.fetchProfiles(family: fixtures.hero.family.recordID.recordName).first { $0.recordName == fixtures.hero.id.recordName }?.payoutPolicyEnum == nil)
    }

    @Test
    func `updateProfilePayoutDay throws unauthorized for non-parent non-self hero`() async {
        let deps = makeDependencies()
        let fixtures = makeStandardFixtures()
        let hero2 = Profile(
            displayName: "Hero 2",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "u2", zoneID: fixtures.zoneID),
            family: fixtures.familyRef,
            id: CKRecord.ID(recordName: "hero2", zoneID: fixtures.zoneID)
        )

        deps.appState.currentProfile = hero2
        await #expect(throws: FamilyServiceError.unauthorized) {
            try await deps.familyService.updateProfilePayoutDay(profile: fixtures.hero, day: .friday)
        }
    }

    @Test
    func `updateProfilePayoutDay succeeds when self or parent`() async throws {
        let deps = makeDependencies()
        let cache = try CacheService(inMemory: true)
        deps.familyService.cacheService = cache

        let fixtures = makeStandardFixtures()
        await cache.upsertProfile(fixtures.hero)
        deps.cloudKit.seedMockRecords([fixtures.hero])

        // Self hero
        deps.appState.currentProfile = fixtures.hero
        let savedBySelf = try await deps.familyService.updateProfilePayoutDay(profile: fixtures.hero, day: .saturday)
        #expect(savedBySelf.payoutDay == PayoutDay.saturday)

        // Parent
        deps.appState.currentProfile = fixtures.parent
        let savedByParent = try await deps.familyService.updateProfilePayoutDay(profile: fixtures.hero, day: .friday)
        #expect(savedByParent.payoutDay == PayoutDay.friday)
    }

    @Test
    func `deleteFamilyAndReset throws unauthorized when not parent or not zone owner`() async throws {
        let deps = makeDependencies()
        let fixtures = makeStandardFixtures()
        // WHY resolved non-owner anchor: denial must come from the owner check, not legacy nil fallback.
        deps.cloudKit.seedMockRecords([fixtures.family], creatorUserRecordName: "someoneElse")
        let anchoredFamily = try await deps.cloudKit.fetch(Family.self, id: fixtures.family.id)
        deps.appState.family = anchoredFamily
        deps.appState.familyZoneID = anchoredFamily.id.zoneID
        deps.cloudKit.activeFamilyZoneID = anchoredFamily.id.zoneID

        // Case 1: Hero acting, zone owner true
        deps.appState.isZoneOwner = true
        deps.cloudKit.activeIsOwner = true
        deps.appState.currentProfile = fixtures.hero
        await #expect(throws: FamilyServiceError.unauthorized) {
            try await deps.familyService.deleteFamilyAndReset(family: anchoredFamily)
        }

        // Case 2: Parent acting, zone owner false
        deps.appState.isZoneOwner = false
        deps.cloudKit.activeIsOwner = false
        deps.appState.currentProfile = fixtures.parent
        await #expect(throws: FamilyServiceError.unauthorized) {
            try await deps.familyService.deleteFamilyAndReset(family: anchoredFamily)
        }
    }

    @Test
    func `deleteFamilyAndReset succeeds when parent and zone owner`() async throws {
        let deps = makeDependencies()
        let fixtures = makeStandardFixtures()
        // WHY explicit owner anchor: owner-gated delete resolves against the mock's server-authenticated user.
        deps.cloudKit.seedMockRecords([fixtures.family], creatorUserRecordName: Self.mockOwner)
        let anchoredFamily = try await deps.cloudKit.fetch(Family.self, id: fixtures.family.id)

        deps.appState.family = anchoredFamily
        deps.appState.familyZoneID = fixtures.zoneID
        deps.appState.isZoneOwner = true
        deps.cloudKit.activeFamilyZoneID = fixtures.zoneID
        deps.cloudKit.activeIsOwner = true
        deps.appState.currentProfile = fixtures.parent

        try await deps.familyService.deleteFamilyAndReset(family: anchoredFamily)
        #expect(deps.appState.currentProfile == nil)
    }

    @Test
    func `updateProfileDisplayName throws unauthorized for non-self`() async {
        let deps = makeDependencies()
        let fixtures = makeStandardFixtures()
        let hero2 = Profile(
            displayName: "Hero 2",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "u2", zoneID: fixtures.zoneID),
            family: fixtures.familyRef,
            id: CKRecord.ID(recordName: "hero2", zoneID: fixtures.zoneID)
        )

        // hero2 attempting to change hero1's name
        deps.appState.currentProfile = hero2
        await #expect(throws: FamilyServiceError.unauthorized) {
            try await deps.familyService.updateProfileDisplayName(profile: fixtures.hero, newName: "New Name")
        }
    }

    @Test
    func `updateProfileDisplayName succeeds when self`() async throws {
        let deps = makeDependencies()
        let cache = try CacheService(inMemory: true)
        deps.familyService.cacheService = cache

        let fixtures = makeStandardFixtures()
        await cache.upsertProfile(fixtures.hero)
        deps.cloudKit.seedMockRecords([fixtures.hero])
        deps.appState.currentProfile = fixtures.hero

        let updated = try await deps.familyService.updateProfileDisplayName(profile: fixtures.hero, newName: "New Name")
        #expect(updated.displayName == "New Name")
    }

    @Test
    func `updateProfileAvatar throws unauthorized for non-self`() async {
        let deps = makeDependencies()
        let fixtures = makeStandardFixtures()
        let hero2 = Profile(
            displayName: "Hero 2",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "u2", zoneID: fixtures.zoneID),
            family: fixtures.familyRef,
            id: CKRecord.ID(recordName: "hero2", zoneID: fixtures.zoneID)
        )

        deps.appState.currentProfile = hero2
        await #expect(throws: FamilyServiceError.unauthorized) {
            try await deps.familyService.updateProfileAvatar(profile: fixtures.hero, avatarClass: .mage, avatarPresetID: "mage_01", customAvatarImageData: nil)
        }
    }

    @Test
    func `updateProfileAvatar succeeds when self`() async throws {
        let deps = makeDependencies()
        let cache = try CacheService(inMemory: true)
        deps.familyService.cacheService = cache

        let fixtures = makeStandardFixtures()
        await cache.upsertProfile(fixtures.hero)
        deps.cloudKit.seedMockRecords([fixtures.hero])
        deps.appState.currentProfile = fixtures.hero

        let updated = try await deps.familyService.updateProfileAvatar(profile: fixtures.hero, avatarClass: .mage, avatarPresetID: "mage_01", customAvatarImageData: nil)
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
        let deps = makeDependencies()
        let fixtures = makeStandardFixtures()
        let ownerProfile = Profile(
            displayName: "Founding GM",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "u1"),
            family: fixtures.familyRef
        )

        let result = try await deps.familyService.createFamily(name: "Anchored Guild", ownerProfile: ownerProfile)

        // The mock's `save` emulates the server: it stamps the acting user
        // ("mockUser") as the family's creator and re-decodes the record, so the
        // returned family carries the server-authenticated creator anchor.
        #expect(result.family.creatorUserRecordName == Self.mockOwner)
    }

    @Test
    func `fetch applies the mock's server-stamped creator`() async throws {
        let fixtures = makeStandardFixtures()
        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = fixtures.zoneID
        cloudKit.seedMockRecords([fixtures.family], creatorUserRecordName: Self.mockOwner)

        let fetched = try await cloudKit.fetch(Family.self, id: fixtures.family.id)

        // The seeded `Family` never authored the creator locally — the mock's
        // server-stamp registry supplies it on the read path.
        #expect(fetched.creatorUserRecordName == Self.mockOwner)
    }

    @Test
    func `deleteFamilyAndReset throws unauthorized when mock-stamped creator is not the acting user`() async throws {
        let deps = makeDependencies()
        let fixtures = makeStandardFixtures()
        // The real (mock) identity is "mockUser"; the family's server-stamped
        // creator is a DIFFERENT iCloud user, so the forged role field cannot
        // grant the irreversible delete.
        deps.cloudKit.seedMockRecords([fixtures.family], creatorUserRecordName: "someoneElse")
        let anchoredFamily = try await deps.cloudKit.fetch(Family.self, id: fixtures.family.id)
        deps.appState.family = anchoredFamily
        deps.appState.familyZoneID = anchoredFamily.id.zoneID
        deps.appState.isZoneOwner = true
        deps.cloudKit.activeFamilyZoneID = anchoredFamily.id.zoneID
        deps.cloudKit.activeIsOwner = true
        deps.appState.currentProfile = nil

        await #expect(throws: FamilyServiceError.unauthorized) {
            try await deps.familyService.deleteFamilyAndReset(family: anchoredFamily)
        }
    }

    @Test
    func `deleteFamilyAndReset succeeds when mock-stamped creator matches the acting user`() async throws {
        let deps = makeDependencies()
        let fixtures = makeStandardFixtures()
        // Creator stamped by the mock as the mock's current user ("mockUser"),
        // so owner-gated delete is authorized.
        deps.cloudKit.seedMockRecords([fixtures.family], creatorUserRecordName: Self.mockOwner)
        let anchoredFamily = try await deps.cloudKit.fetch(Family.self, id: fixtures.family.id)
        deps.appState.family = anchoredFamily
        deps.appState.familyZoneID = fixtures.zoneID
        deps.appState.isZoneOwner = true
        deps.appState.currentProfile = nil

        try await deps.familyService.deleteFamilyAndReset(family: anchoredFamily)
        #expect(deps.appState.currentProfile == nil)
    }

    @Test
    func `updateMemberRole throws unauthorized when mock-stamped creator is not the acting user`() async throws {
        let deps = makeDependencies()
        let cache = try CacheService(inMemory: true)
        deps.familyService.cacheService = cache

        let fixtures = makeStandardFixtures()
        // The family is mocked — NOT cached — so `family(for:)` reads CloudKit
        // and sees the server stamp of a DIFFERENT iCloud user than the acting
        // "mockUser" identity.
        deps.cloudKit.seedMockRecords([fixtures.family, fixtures.hero], creatorUserRecordName: "someoneElse")
        let forgedGM = Profile(
            displayName: "Forged GM",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "forged", zoneID: fixtures.zoneID),
            family: fixtures.familyRef,
            id: CKRecord.ID(recordName: "forged-gm", zoneID: fixtures.zoneID)
        )
        deps.appState.family = fixtures.family
        deps.appState.currentProfile = forgedGM

        await #expect(throws: FamilyServiceError.unauthorized) {
            try await deps.familyService.updateMemberRole(profile: fixtures.hero, newRole: .ranger)
        }
    }

    @Test
    func `updateMemberRole succeeds when mock-stamped creator matches the acting user`() async throws {
        let deps = makeDependencies()
        let cache = try CacheService(inMemory: true)
        deps.familyService.cacheService = cache

        let fixtures = makeStandardFixtures()
        // Creator stamped by the mock as the mock's current user ("mockUser"),
        // so the owner anchor authorizes the role change.
        deps.cloudKit.seedMockRecords([fixtures.family, fixtures.hero], creatorUserRecordName: Self.mockOwner)
        let owner = Profile(
            displayName: "Owner",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "owner", zoneID: fixtures.zoneID),
            family: fixtures.familyRef,
            id: CKRecord.ID(recordName: "owner-gm", zoneID: fixtures.zoneID)
        )
        deps.appState.family = fixtures.family
        deps.appState.currentProfile = owner

        try await deps.familyService.updateMemberRole(profile: fixtures.hero, newRole: .ranger)

        let cachedHero = cache.fetchProfiles(family: "fam1").first { $0.recordName == fixtures.hero.id.recordName }
        #expect(cachedHero?.role == UserRole.ranger.rawValue)
    }

    @Test
    func `kickMember throws unauthorized when mock-stamped creator is not the acting user`() async throws {
        let deps = makeDependencies()
        let cache = try CacheService(inMemory: true)
        deps.familyService.cacheService = cache

        let fixtures = makeStandardFixtures()
        // Anchor set to "someoneElse" — not the current acting user ("mockUser").
        deps.cloudKit.seedMockRecords([fixtures.family, fixtures.hero], creatorUserRecordName: "someoneElse")
        let attacker = Profile(
            displayName: "Pretender GM",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "attacker", zoneID: fixtures.zoneID),
            family: fixtures.familyRef,
            id: CKRecord.ID(recordName: "attacker", zoneID: fixtures.zoneID)
        )
        deps.appState.family = fixtures.family
        deps.appState.currentProfile = attacker

        await #expect(throws: FamilyServiceError.unauthorized) {
            try await deps.familyService.kickMember(profile: fixtures.hero)
        }
    }

    @Test
    func `kickMember succeeds when mock-stamped creator matches the acting user`() async throws {
        let deps = makeDependencies()
        let cache = try CacheService(inMemory: true)
        deps.familyService.cacheService = cache

        let fixtures = makeStandardFixtures()
        deps.cloudKit.seedMockRecords([fixtures.family, fixtures.hero], creatorUserRecordName: Self.mockOwner)
        let owner = Profile(
            displayName: "True GM",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "owner", zoneID: fixtures.zoneID),
            family: fixtures.familyRef,
            id: CKRecord.ID(recordName: "owner-gm", zoneID: fixtures.zoneID)
        )
        deps.appState.family = fixtures.family
        deps.appState.currentProfile = owner

        try await deps.familyService.kickMember(profile: fixtures.hero)
        let cachedHero = cache.fetchProfiles(family: "fam1").first { $0.recordName == fixtures.hero.id.recordName }
        #expect(cachedHero?.isActive == false)
    }

    @Test
    func `updateMemberRole throws unauthorized when anchored creator mismatches acting user`() async throws {
        let deps = makeDependencies()
        let cache = try CacheService(inMemory: true)
        deps.familyService.cacheService = cache

        let fixtures = makeStandardFixtures()
        await cache.upsertProfile(fixtures.hero)
        // WHY resolved non-owner anchor: owner-gated writes deny even for a parent role when the creator mismatches.
        deps.cloudKit.seedMockRecords([fixtures.family, fixtures.hero], creatorUserRecordName: "someoneElse")
        let parent = Profile(
            displayName: "Guild Master",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "gm1", zoneID: fixtures.zoneID),
            family: fixtures.familyRef,
            id: CKRecord.ID(recordName: "gm1", zoneID: fixtures.zoneID)
        )
        deps.appState.family = fixtures.family
        deps.appState.currentProfile = parent

        await #expect(throws: FamilyServiceError.unauthorized) {
            try await deps.familyService.updateMemberRole(profile: fixtures.hero, newRole: .ranger)
        }
    }
}
