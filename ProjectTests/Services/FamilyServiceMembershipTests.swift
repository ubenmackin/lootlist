//
//  FamilyServiceMembershipTests.swift
//  LootList
//
//  Created by Ben Mackin on 10/18/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

/// Covering the shared-identity participation guard on membership removal:
/// share participants are keyed by iCloudUserID, so two profiles bound to one
/// Apple ID must keep their participant while either profile is still active.
@MainActor
struct FamilyServiceMembershipTests {
    struct Dependencies {
        let familyService: FamilyService
        let cloudKit: MockCloudKitService
        let appState: AppState
        let cache: CacheService
    }

    struct SharedIdentityRoster {
        let family: Family
        let leavingProfile: Profile
        let siblingProfile: Profile
        let guildMaster: Profile
        let identityRecordName: String

        /// Key format the mock share memberships use for iCloud record identities.
        var shareIdentityKey: String {
            "record:\(identityRecordName)"
        }
    }

    /// Both hero profiles bind to one iCloud identity; `identityRecordName`
    /// also decides whether the leaver self-resolves as family owner (leave path).
    func makeSharedIdentityHarness(identityRecordName: String) throws -> (Dependencies, SharedIdentityRoster) {
        let zoneID = ExhaustiveCacheFixtures.sharedZoneID
        let familyRef = ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID)
        let family = ExhaustiveCacheFixtures.sharedFamily(zoneID: zoneID)
        let sharedIdentity = ExhaustiveCacheFixtures.id(identityRecordName, zoneID: zoneID)
        let leavingProfile = Profile(
            displayName: "Shared Kid One",
            role: .hero,
            iCloudUserID: sharedIdentity,
            family: familyRef,
            id: ExhaustiveCacheFixtures.id("hero-sibling-one", zoneID: zoneID)
        )
        let siblingProfile = Profile(
            displayName: "Shared Kid Two",
            role: .hero,
            iCloudUserID: sharedIdentity,
            family: familyRef,
            id: ExhaustiveCacheFixtures.id("hero-sibling-two", zoneID: zoneID)
        )
        let guildMaster = Profile(
            displayName: "Guild Master",
            role: .guildMaster,
            iCloudUserID: ExhaustiveCacheFixtures.id("gm1", zoneID: zoneID),
            family: familyRef,
            id: ExhaustiveCacheFixtures.id("gm1", zoneID: zoneID)
        )

        let cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        cloudKit.activeIsOwner = true
        let appState = AppState(defaults: .ephemeral())
        appState.isZoneOwner = true
        appState.familyZoneID = zoneID
        appState.family = family
        let xpService = XPService(cloudKit: cloudKit, appState: appState)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService, appState: appState)
        let familyService = FamilyService(cloudKit: cloudKit, appState: appState, questService: questService)
        let cache = try CacheService(inMemory: true)
        familyService.cacheService = cache

        // The family fixture's creator anchor matches the mock's server-authenticated user.
        cloudKit.seedMockRecords(
            [family, leavingProfile, siblingProfile],
            creatorUserRecordName: MockCloudKitService.mockUserRecordName
        )

        let deps = Dependencies(
            familyService: familyService,
            cloudKit: cloudKit,
            appState: appState,
            cache: cache
        )
        let roster = SharedIdentityRoster(
            family: family,
            leavingProfile: leavingProfile,
            siblingProfile: siblingProfile,
            guildMaster: guildMaster,
            identityRecordName: identityRecordName
        )
        return (deps, roster)
    }

    @Test
    func `kicking one of two profiles sharing an iCloud identity keeps the participant`() async throws {
        let (deps, roster) = try makeSharedIdentityHarness(identityRecordName: "shared-apple-id")
        await deps.cache.upsertFamily(roster.family)
        await deps.cache.upsertProfile(roster.leavingProfile)
        await deps.cache.upsertProfile(roster.siblingProfile)
        deps.appState.currentProfile = roster.guildMaster
        let share = try await deps.cloudKit.simulateParticipation(
            key: roster.shareIdentityKey,
            rootRecordID: roster.family.id,
            role: .hero
        )

        let result = try await deps.familyService.kickMember(profile: roster.leavingProfile)

        guard case .participantKeptSharedIdentity = result else {
            #expect(Bool(false), "Expected participantKeptSharedIdentity, got \(result)")
            return
        }
        // The share stays intact so the sibling on the same Apple ID keeps device access.
        #expect(deps.cloudKit.mockShareMemberships[share.recordID]?.contains(roster.shareIdentityKey) == true)
        #expect(deps.cloudKit.revokedShareIDs.isEmpty)
        let cachedLeaving = deps.cache.fetchProfiles(family: roster.family.id.recordName)
            .first { $0.recordName == roster.leavingProfile.id.recordName }
        let cachedSibling = deps.cache.fetchProfiles(family: roster.family.id.recordName)
            .first { $0.recordName == roster.siblingProfile.id.recordName }
        #expect(cachedLeaving?.isActive == false)
        #expect(cachedSibling?.isActive == true)
    }

    @Test
    func `kicking a sole-profile member still removes the participant`() async throws {
        let (deps, roster) = try makeSharedIdentityHarness(identityRecordName: "shared-apple-id")
        await deps.cache.upsertFamily(roster.family)
        await deps.cache.upsertProfile(roster.leavingProfile)
        deps.appState.currentProfile = roster.guildMaster
        let share = try await deps.cloudKit.simulateParticipation(
            key: roster.shareIdentityKey,
            rootRecordID: roster.family.id,
            role: .hero
        )

        let result = try await deps.familyService.kickMember(profile: roster.leavingProfile)

        #expect(result == .fully)
        #expect(deps.cloudKit.revokedShareIDs.count == 1)
        #expect(deps.cloudKit.revokedShareIDs.first == share.recordID)
        #expect(deps.cloudKit.mockShareMemberships[share.recordID]?.contains(roster.shareIdentityKey) == false)
    }

    @Test
    func `kick with an unreadable roster keeps the participant fail-closed`() async throws {
        let (deps, roster) = try makeSharedIdentityHarness(identityRecordName: "shared-apple-id")
        await deps.cache.upsertFamily(roster.family)
        await deps.cache.upsertProfile(roster.leavingProfile)
        deps.appState.currentProfile = roster.guildMaster
        let share = try await deps.cloudKit.simulateParticipation(
            key: roster.shareIdentityKey,
            rootRecordID: roster.family.id,
            role: .hero
        )

        deps.familyService.cacheService = nil
        #expect(deps.familyService.hasActiveSharedIdentitySibling(for: roster.leavingProfile) == true)

        let result = try await deps.familyService.kickMember(profile: roster.leavingProfile)

        guard case .participantKeptSharedIdentity = result else {
            #expect(Bool(false), "Expected participantKeptSharedIdentity, got \(result)")
            return
        }
        #expect(deps.cloudKit.mockShareMemberships[share.recordID]?.contains(roster.shareIdentityKey) == true)
        #expect(deps.cloudKit.revokedShareIDs.isEmpty)
    }

    @Test
    func `self-leave with a shared-iCloud sibling keeps the participant and clears the session`() async throws {
        // The leaver carries the creator identity, so self-leave reaches the
        // resolved-owner participant-removal branch instead of skipping it.
        let (deps, roster) = try makeSharedIdentityHarness(identityRecordName: MockCloudKitService.mockUserRecordName)
        await deps.cache.upsertFamily(roster.family)
        await deps.cache.upsertProfile(roster.leavingProfile)
        await deps.cache.upsertProfile(roster.siblingProfile)
        deps.appState.currentProfile = roster.leavingProfile
        let share = try await deps.cloudKit.simulateParticipation(
            key: roster.shareIdentityKey,
            rootRecordID: roster.family.id,
            role: .hero
        )

        try await deps.familyService.leaveFamily(profile: roster.leavingProfile)

        // Nothing revoked, the sibling keeps device access, and the leaver's
        // local session still clears exactly as before.
        #expect(deps.cloudKit.mockShareMemberships[share.recordID]?.contains(roster.shareIdentityKey) == true)
        #expect(deps.cloudKit.revokedShareIDs.isEmpty)
        #expect(deps.appState.family == nil)
        let cachedLeaving = deps.cache.fetchProfiles(family: roster.family.id.recordName)
            .first { $0.recordName == roster.leavingProfile.id.recordName }
        #expect(cachedLeaving?.isActive == false)
    }
}
