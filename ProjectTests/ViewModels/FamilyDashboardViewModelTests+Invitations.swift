//
//  FamilyDashboardViewModelTests+Invitations.swift
//  LootList
//
//  Created by Ben Mackin on 8/19/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

// MARK: - Stubs for Invitations panel tests

@MainActor
final class StubFamilyProfileFetcher: FamilyProfileFetching {
    private let profiles: [Profile]
    let cloudKit: MockCloudKitService
    var refreshProfilesCallCount = 0

    init(profiles: [Profile] = [], cloudKit: MockCloudKitService = MockCloudKitService()) {
        self.profiles = profiles
        self.cloudKit = cloudKit
    }

    func fetchAllProfilesForFamily(_: Family) async throws -> [Profile] {
        profiles
    }

    func refreshProfilesFromCloudKit(for _: Family) async {
        refreshProfilesCallCount += 1
    }

    func currentUserRecordName() async throws -> String {
        try await cloudKit.currentUserRecordID().recordName
    }

    func prepareInviteShare(for family: Family, role: UserRole) async throws -> CKShare {
        try await cloudKit.fetchOrCreateShare(for: family.id, role: role)
    }

    func fetchShareParticipants(for family: Family) async throws -> [CKShare.Participant] {
        try await cloudKit.fetchShareParticipants(for: family.id)
    }

    func fetchShareParticipantStatuses(for family: Family) async throws -> [ShareParticipantStatus] {
        try await cloudKit.fetchShareParticipantStatuses(for: family.id)
    }

    func fetchShareParticipantRoles(for family: Family) async throws -> [String: UserRole] {
        try await cloudKit.fetchShareParticipantRoles(for: family.id)
    }

    func revokeInvitation(participant: CKShare.Participant, from family: Family) async throws {
        try await cloudKit.removeParticipant(participant, from: family.id)
    }

    func revokeInvitation(identityRecordName: String, from family: Family) async throws {
        try await cloudKit.removeParticipant(iCloudUserRecordName: identityRecordName, from: family.id)
    }
}

@MainActor
final class MutableStubFamilyProfileFetcher: FamilyProfileFetching {
    var profiles: [Profile]
    let cloudKit: MockCloudKitService
    var refreshProfilesCallCount = 0

    init(profiles: [Profile] = [], cloudKit: MockCloudKitService = MockCloudKitService()) {
        self.profiles = profiles
        self.cloudKit = cloudKit
    }

    func fetchAllProfilesForFamily(_: Family) async throws -> [Profile] {
        profiles
    }

    func refreshProfilesFromCloudKit(for _: Family) async {
        refreshProfilesCallCount += 1
    }

    func currentUserRecordName() async throws -> String {
        try await cloudKit.currentUserRecordID().recordName
    }

    func prepareInviteShare(for family: Family, role: UserRole) async throws -> CKShare {
        try await cloudKit.fetchOrCreateShare(for: family.id, role: role)
    }

    func fetchShareParticipants(for family: Family) async throws -> [CKShare.Participant] {
        try await cloudKit.fetchShareParticipants(for: family.id)
    }

    func fetchShareParticipantStatuses(for family: Family) async throws -> [ShareParticipantStatus] {
        try await cloudKit.fetchShareParticipantStatuses(for: family.id)
    }

    func fetchShareParticipantRoles(for family: Family) async throws -> [String: UserRole] {
        try await cloudKit.fetchShareParticipantRoles(for: family.id)
    }

    func revokeInvitation(participant: CKShare.Participant, from family: Family) async throws {
        try await cloudKit.removeParticipant(participant, from: family.id)
    }

    func revokeInvitation(identityRecordName: String, from family: Family) async throws {
        try await cloudKit.removeParticipant(iCloudUserRecordName: identityRecordName, from: family.id)
    }
}

// MARK: - Invitations Panel Tests

extension FamilyDashboardViewModelTests {
    private func makeInvitationSUT(
        fetcher: FamilyProfileFetching,
        family: Family
    ) -> (vm: FamilyDashboardViewModel, cloudKit: MockCloudKitService) {
        // Reuse the fetcher's backing mock so simulateParticipation state
        // written via the returned cloudKit is visible to the fetcher's
        // invitation methods — both must share the same MockRecordStore.
        let cloudKit: MockCloudKitService = if let stub = fetcher as? StubFamilyProfileFetcher {
            stub.cloudKit
        } else if let mutable = fetcher as? MutableStubFamilyProfileFetcher {
            mutable.cloudKit
        } else {
            MockCloudKitService()
        }
        cloudKit.activeFamilyZoneID = family.id.zoneID
        let xpService = XPService(cloudKit: cloudKit)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService)
        let treasury = TreasuryService(cloudKit: cloudKit)
        let achievementService = AchievementService(cloudKit: cloudKit)
        let appState = AppState()
        appState.family = family
        appState.isZoneOwner = true
        let vm = FamilyDashboardViewModel(
            questService: questService,
            treasury: treasury,
            achievementService: achievementService,
            familyService: fetcher,
            appState: appState
        )
        return (vm, cloudKit)
    }

    /// A minimal active hero roster entry bound to the given iCloud identity.
    private func makeHeroCache(
        recordName: String,
        iCloudUserRecordName: String,
        familyRecordName: String = "fam1"
    ) -> ProfileCache {
        ProfileCache(
            recordName: recordName,
            familyRecordName: familyRecordName,
            displayName: "Hero \(recordName)",
            role: "hero",
            xpTotal: 0,
            avatarName: nil,
            customAvatarImageData: nil,
            isActive: true,
            level: 1,
            iCloudUserRecordName: iCloudUserRecordName,
            avatarClass: nil,
            payoutPolicy: "perQuest"
        )
    }

    @Test
    func `refreshInvitations flags departed members and removed identities`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let family = Family(
            name: "Test Family",
            createdBy: CKRecord.ID(recordName: "owner1", zoneID: zoneID),
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        var departedHero = Profile(
            displayName: "Departed Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "u1", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        )
        departedHero.isActive = false

        let fetcher = StubFamilyProfileFetcher(profiles: [departedHero])
        let (vm, cloudKit) = makeInvitationSUT(fetcher: fetcher, family: family)

        // Departed member: deactivated Profile whose identity is still an
        // accepted participant — surfaced so the GM can revoke share access.
        _ = try await cloudKit.simulateParticipation(key: "record:u1", rootRecordID: family.id, role: .hero)
        // Revoked identity: `.removed` status surfaces read-only.
        _ = try await cloudKit.simulateParticipation(key: "record:u2", rootRecordID: family.id, role: .hero)
        cloudKit.mockRemovedMemberships.insert("record:u2")

        await vm.refreshInvitations()

        #expect(vm.invitations.count == 2)
        let departed = vm.invitations.first { $0.kind == .departedMember }
        #expect(departed?.identity == "Departed Hero")
        #expect(departed?.statusText.contains("revoke share access") == true)
        let removed = vm.invitations.first { $0.kind == .removedIdentity }
        // Display labels are redacted: the raw iCloud record name must never
        // surface in the panel — only the stable opaque token remains.
        #expect(removed?.identity.hasPrefix("Guild Member") == true)
        #expect(removed?.identity.contains("u2") == false)
        #expect(removed?.statusText == "Removed")
    }

    @Test
    func `email or phone removed participant is classified as removedIdentity`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let family = Family(
            name: "Test Family",
            createdBy: CKRecord.ID(recordName: "owner1", zoneID: zoneID),
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
        let fetcher = StubFamilyProfileFetcher()
        let (vm, cloudKit) = makeInvitationSUT(fetcher: fetcher, family: family)

        // Email-only invite marked as removed. The panel classifies the row
        // from the status list; its display label is redacted, so the lookup
        // keys off the classification rather than the raw email address.
        _ = try await cloudKit.simulateParticipation(key: "email:hero@test.com", rootRecordID: family.id, role: .hero)
        cloudKit.mockRemovedMemberships.insert("email:hero@test.com")

        await vm.refreshInvitations()

        let removed = try #require(vm.invitations.first { $0.kind == .removedIdentity })
        #expect(removed.kind == .removedIdentity)
        // The email address must never surface in the display label.
        #expect(removed.identity.hasPrefix("Guild Member") == true)
        #expect(removed.identity.contains("hero@test.com") == false)
        #expect(removed.statusText == "Removed")
    }

    @Test
    func `revoking a departed member strips their lingering share access`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let family = Family(
            name: "Test Family",
            createdBy: CKRecord.ID(recordName: "owner1", zoneID: zoneID),
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        var departedHero = Profile(
            displayName: "Departed Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "u1", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        )
        departedHero.isActive = false

        let fetcher = StubFamilyProfileFetcher(profiles: [departedHero])
        let (vm, cloudKit) = makeInvitationSUT(fetcher: fetcher, family: family)
        _ = try await cloudKit.simulateParticipation(key: "record:u1", rootRecordID: family.id, role: .hero)

        await vm.refreshInvitations()
        let departed = try #require(vm.invitations.first { $0.kind == .departedMember })

        await vm.revokeInvitation(departed)

        // The row is removed from the panel and the identity's membership is
        // stripped from the share. When no participant object is available the
        // revocation falls back to the identity record name.
        #expect(!vm.invitations.contains { $0.id == departed.id })
        #expect(!cloudKit.revokedShareIDs.isEmpty)
        let statuses = try await cloudKit.fetchShareParticipantStatuses(for: family.id)
        #expect(!statuses.contains { $0.recordName == "u1" })
    }

    @Test
    func `a failed revocation surfaces loadError so the panel is never silent`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let family = Family(
            name: "Test Family",
            createdBy: CKRecord.ID(recordName: "owner1", zoneID: zoneID),
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        var departedHero = Profile(
            displayName: "Departed Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "u1", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        )
        departedHero.isActive = false

        let fetcher = StubFamilyProfileFetcher(profiles: [departedHero])
        let (vm, cloudKit) = makeInvitationSUT(fetcher: fetcher, family: family)
        _ = try await cloudKit.simulateParticipation(key: "record:u1", rootRecordID: family.id, role: .hero)

        await vm.refreshInvitations()
        let departed = try #require(vm.invitations.first { $0.kind == .departedMember })
        vm.loadError = nil

        // Removing participant before revocation surfaces error via loadError.
        try await cloudKit.removeParticipant(iCloudUserRecordName: "u1", from: family.id)
        await vm.revokeInvitation(departed)

        #expect(vm.loadError != nil)
        // The row is kept so the GM can retry once the race resolves.
        #expect(vm.invitations.contains { $0.id == departed.id })
    }

    @Test
    func `accepted member with a lingering participant row is not offered for revoke`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let family = Family(
            name: "Test Family",
            createdBy: CKRecord.ID(recordName: "owner1", zoneID: zoneID),
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let hero = Profile(
            displayName: "New Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "u1", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        )
        let fetcher = StubFamilyProfileFetcher(profiles: [hero])
        let (vm, cloudKit) = makeInvitationSUT(fetcher: fetcher, family: family)

        // The hero accepted the invite: their identity still holds a share
        // participant row, but the roster already contains their active
        // Profile, so the panel must not classify them as a revocable invite.
        _ = try await cloudKit.simulateParticipation(key: "record:u1", rootRecordID: family.id, role: .hero)
        vm.rebuildLists(
            profiles: [makeHeroCache(recordName: "hero1", iCloudUserRecordName: "u1")],
            quests: [],
            logs: [],
            ledgers: [],
            allowancePeriods: [],
            profileAchievements: [],
            achievements: []
        )

        await vm.refreshInvitations()

        #expect(!vm.invitations.contains { $0.identityRecordName == "u1" })
        #expect(!vm.invitations.contains { $0.kind == .pendingInvite })
    }

    @Test
    func `kicked member is dropped once the roster refresh re-runs classification`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let family = Family(
            name: "Test Family",
            createdBy: CKRecord.ID(recordName: "owner1", zoneID: zoneID),
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let hero = Profile(
            displayName: "Hero One",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "u1", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        )
        let fetcher = MutableStubFamilyProfileFetcher(profiles: [])
        let (vm, cloudKit) = makeInvitationSUT(fetcher: fetcher, family: family)
        _ = try await cloudKit.simulateParticipation(key: "record:u1", rootRecordID: family.id, role: .hero)

        // Cold-start window: the roster has not caught up yet, so the
        // participant row is (correctly, at this instant) a revocable pending
        // invite.
        await vm.refreshInvitations()
        #expect(vm.invitations.contains { $0.identityRecordName == "u1" && $0.kind == .pendingInvite })

        // The hero accepts: the roster now contains them, and the roster-change
        // refresh re-classifies the row out of the panel.
        fetcher.profiles = [hero]
        vm.rebuildLists(
            profiles: [makeHeroCache(recordName: "hero1", iCloudUserRecordName: "u1")],
            quests: [],
            logs: [],
            ledgers: [],
            allowancePeriods: [],
            profileAchievements: [],
            achievements: []
        )
        await vm.refreshInvitations()
        #expect(!vm.invitations.contains { $0.identityRecordName == "u1" })

        // The member is kicked: the Profile is gone and their share access is
        // revoked. After the roster-change refresh the panel is empty — the
        // stale revocable row from the cold window must not linger.
        fetcher.profiles = []
        vm.rebuildLists(
            profiles: [],
            quests: [],
            logs: [],
            ledgers: [],
            allowancePeriods: [],
            profileAchievements: [],
            achievements: []
        )
        try await cloudKit.removeParticipant(iCloudUserRecordName: "u1", from: family.id)
        await vm.refreshInvitations()
        #expect(vm.invitations.isEmpty)
    }

    @Test
    func `owner and current user identity are never revocable on a cold-start window`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let family = Family(
            name: "Test Family",
            createdBy: CKRecord.ID(recordName: "owner1", zoneID: zoneID),
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
        // Empty cache: no profiles, no roster — the panel's worst-case window.
        let fetcher = StubFamilyProfileFetcher()
        let (vm, cloudKit) = makeInvitationSUT(fetcher: fetcher, family: family)

        // The share owner's participant entry is the signed-in user's identity.
        // Without the self-exclusion it would be misclassified as a revocable
        // "Accepted" invite during the empty-cache window.
        let ownerRecordName = try await cloudKit.currentUserRecordID().recordName
        _ = try await cloudKit.simulateParticipation(key: "record:\(ownerRecordName)", rootRecordID: family.id, role: .hero)

        await vm.refreshInvitations()

        #expect(vm.invitations.isEmpty)
        #expect(!vm.invitations.contains { $0.identityRecordName == ownerRecordName })
    }

    @Test
    func `refreshInvitations pulls missing accepted member profiles from CloudKit`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let family = Family(
            name: "Test Family",
            createdBy: CKRecord.ID(recordName: "owner1", zoneID: zoneID),
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let childHero = Profile(
            displayName: "Child Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "child_user_1", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "child_profile_1", zoneID: zoneID)
        )

        let fetcher = MutableStubFamilyProfileFetcher(profiles: [childHero])
        let (vm, cloudKit) = makeInvitationSUT(fetcher: fetcher, family: family)

        // Simulate that child accepted the share link on CloudKit
        _ = try await cloudKit.simulateParticipation(key: "record:child_user_1", rootRecordID: family.id, role: .hero)

        // Local cache currently only has the parent (empty heroes)
        vm.rebuildLists(
            profiles: [],
            quests: [],
            logs: [],
            ledgers: [],
            allowancePeriods: [],
            profileAchievements: [],
            achievements: []
        )

        await vm.refreshInvitations()

        // Verify that refreshProfilesFromCloudKit was invoked to fetch the missing member
        #expect(fetcher.refreshProfilesCallCount > 0)
        // Because the profile was fetched, it is excluded from invitations (not displayed as a pending invite)
        #expect(!vm.invitations.contains { $0.identityRecordName == "child_user_1" })
        #expect(vm.invitations.isEmpty)
    }
}
