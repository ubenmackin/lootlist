//
//  FamilyDashboardViewModelTests.swift
//  LootList
//
//  Created by Ben Mackin on 7/25/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

// MARK: - Mock

@MainActor
private final class MockFamilyProfileFetcher: FamilyProfileFetching {
    private(set) var fetchCallCount = 0

    func fetchAllProfilesForFamily(_: Family) async throws -> [Profile] {
        fetchCallCount += 1
        return []
    }
}

/// Returns a fixed profile list, for invitation-panel classification tests.
@MainActor
private final class StubFamilyProfileFetcher: FamilyProfileFetching {
    private let profiles: [Profile]

    init(profiles: [Profile] = []) {
        self.profiles = profiles
    }

    func fetchAllProfilesForFamily(_: Family) async throws -> [Profile] {
        profiles
    }
}

/// A profile fetcher whose returned roster can change between refreshes, for
/// roster-change re-classification tests.
@MainActor
private final class MutableStubFamilyProfileFetcher: FamilyProfileFetching {
    var profiles: [Profile]

    init(profiles: [Profile] = []) {
        self.profiles = profiles
    }

    func fetchAllProfilesForFamily(_: Family) async throws -> [Profile] {
        profiles
    }
}

// MARK: - Tests

@MainActor
struct FamilyDashboardViewModelTests {
    // MARK: - Helpers

    private struct SUT {
        let vm: FamilyDashboardViewModel
        let fetcher: MockFamilyProfileFetcher
        let coordinator: AppSyncCoordinator
    }

    private func makeSUT(
        fetcher: MockFamilyProfileFetcher = MockFamilyProfileFetcher(),
        family: Family? = Family(
            name: "Test Family",
            createdBy: CKRecord.ID(recordName: "owner1")
        )
    ) -> SUT {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService(zoneID: zoneID)
        let xpService = XPService(cloudKit: cloudKit)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService)
        let treasury = TreasuryService(cloudKit: cloudKit)
        let achievementService = AchievementService(cloudKit: cloudKit)
        let appState = AppState()
        appState.family = family

        let vm = FamilyDashboardViewModel(
            questService: questService,
            treasury: treasury,
            achievementService: achievementService,
            familyService: fetcher,
            appState: appState
        )
        let coordinator = AppSyncCoordinator()
        return SUT(vm: vm, fetcher: fetcher, coordinator: coordinator)
    }

    // MARK: - Debounce tests

    @Test
    func `rapid recordChanged events trigger at most one fetch`() async {
        let sut = makeSUT()
        sut.vm.subscribeToSyncEvents(sut.coordinator)

        for index in 0 ..< 5 {
            sut.coordinator.handleDatabaseChange(subscriptionID: "test-sub-\(index)")
        }

        await Task.yield()
        try? await Task.sleep(for: .milliseconds(500))

        #expect(sut.fetcher.fetchCallCount <= 1)

        sut.vm.unsubscribeFromSyncEvents(sut.coordinator)
    }

    @Test
    func `recordChanged does nothing when no family is set`() async {
        let sut = makeSUT(family: nil)
        sut.vm.subscribeToSyncEvents(sut.coordinator)

        sut.coordinator.handleDatabaseChange(subscriptionID: "test-sub")

        await Task.yield()
        try? await Task.sleep(for: .milliseconds(500))

        #expect(sut.fetcher.fetchCallCount == 0)

        sut.vm.unsubscribeFromSyncEvents(sut.coordinator)
    }

    @Test
    func `no retry loop or display name heuristic exists`() {
        let sut = makeSUT()
        let mirror = Mirror(reflecting: sut.vm)
        let propertyNames = mirror.children.compactMap(\.label)

        #expect(!propertyNames.contains("lastHeroDisplayNames"))
        #expect(!propertyNames.contains("scheduleLatePropagationRetry"))
    }

    @Test
    func `zoneReset does not trigger debounced fetch`() async {
        let sut = makeSUT()
        sut.vm.subscribeToSyncEvents(sut.coordinator)

        sut.coordinator.notifyZoneReset()

        await Task.yield()
        // does not touch it, so fetchCallCount stays at 0.
        #expect(sut.fetcher.fetchCallCount == 0)

        sut.vm.unsubscribeFromSyncEvents(sut.coordinator)
    }

    // MARK: - Invitations panel classification

    private func makeInvitationSUT(
        fetcher: FamilyProfileFetching,
        family: Family
    ) -> (vm: FamilyDashboardViewModel, cloudKit: MockCloudKitService) {
        let cloudKit = MockCloudKitService()
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
        try await cloudKit.simulateParticipation(key: "record:u1", rootRecordID: family.id, role: .hero)
        // Revoked identity: `.removed` status surfaces read-only.
        try await cloudKit.simulateParticipation(key: "record:u2", rootRecordID: family.id, role: .hero)
        cloudKit.mockRemovedMemberships.insert("record:u2")

        await vm.refreshInvitations()

        #expect(vm.invitations.count == 2)
        let departed = vm.invitations.first { $0.kind == .departedMember }
        #expect(departed?.identity == "Departed Hero")
        #expect(departed?.statusText.contains("revoke share access") == true)
        let removed = vm.invitations.first { $0.kind == .removedIdentity }
        #expect(removed?.identity == "u2")
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

        // Email-only invite marked as removed
        try await cloudKit.simulateParticipation(key: "email:hero@test.com", rootRecordID: family.id, role: .hero)
        cloudKit.mockRemovedMemberships.insert("email:hero@test.com")

        await vm.refreshInvitations()

        let removed = try #require(vm.invitations.first { $0.identity == "hero@test.com" })
        #expect(removed.kind == .removedIdentity)
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
        try await cloudKit.simulateParticipation(key: "record:u1", rootRecordID: family.id, role: .hero)

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
        try await cloudKit.simulateParticipation(key: "record:u1", rootRecordID: family.id, role: .hero)

        await vm.refreshInvitations()
        let departed = try #require(vm.invitations.first { $0.kind == .departedMember })
        vm.loadError = nil

        // Simulate the propagation race the finding describes: the identity is
        // no longer a member of any role share, so the service throws. The
        // revocation must surface an error (via `loadError`) rather than fail
        // silently while the GM believes access was revoked.
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
        try await cloudKit.simulateParticipation(key: "record:u1", rootRecordID: family.id, role: .hero)
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
        let fetcher = MutableStubFamilyProfileFetcher(profiles: [hero])
        let (vm, cloudKit) = makeInvitationSUT(fetcher: fetcher, family: family)
        try await cloudKit.simulateParticipation(key: "record:u1", rootRecordID: family.id, role: .hero)

        // Cold-start window: the roster has not caught up yet, so the
        // participant row is (correctly, at this instant) a revocable pending
        // invite.
        await vm.refreshInvitations()
        #expect(vm.invitations.contains { $0.identityRecordName == "u1" && $0.kind == .pendingInvite })

        // The hero accepts: the roster now contains them, and the roster-change
        // refresh re-classifies the row out of the panel.
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
        try await cloudKit.simulateParticipation(key: "record:\(ownerRecordName)", rootRecordID: family.id, role: .hero)

        await vm.refreshInvitations()

        #expect(vm.invitations.isEmpty)
        #expect(!vm.invitations.contains { $0.identityRecordName == ownerRecordName })
    }

    @Test
    func `rebuildLists derives streak and trophies from cache arrays`() throws {
        let sut = makeSUT()
        let calendar = Calendar.iso8601UTC
        let today = calendar.startOfDay(for: Date())
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: today))
        let currentWeek = WeekMath.weekOf(date: Date())
        let familyName = "TestFamily"

        let hero = ProfileCache(
            recordName: "hero1",
            familyRecordName: familyName,
            displayName: "Test Hero",
            role: "hero",
            xpTotal: 100,
            avatarName: nil,
            customAvatarImageData: nil,
            isActive: true,
            level: 5,
            iCloudUserRecordName: "u1",
            avatarClass: nil,
            payoutPolicy: "standard"
        )

        let logToday = QuestCompletionCache(
            recordName: "log_today",
            questRecordName: "quest1",
            familyRecordName: familyName,
            completerRecordName: "hero1",
            completedDate: today,
            weekOf: currentWeek,
            verificationStatus: VerificationStatus.autoApproved.rawValue,
            approvalMode: ApprovalMode.autoApprove.rawValue,
            verifiedByRecordName: nil,
            verifiedDate: nil
        )
        let logYesterday = QuestCompletionCache(
            recordName: "log_yesterday",
            questRecordName: "quest2",
            familyRecordName: familyName,
            completerRecordName: "hero1",
            completedDate: yesterday,
            weekOf: currentWeek,
            verificationStatus: VerificationStatus.verified.rawValue,
            approvalMode: ApprovalMode.parentVerify.rawValue,
            verifiedByRecordName: "parent1",
            verifiedDate: yesterday
        )

        let trophy1 = ProfileAchievementCache(
            recordName: "trophy1",
            achievementRecordName: "ach1",
            profileRecordName: "hero1",
            familyRecordName: familyName,
            earnedDate: today
        )
        let trophy2 = ProfileAchievementCache(
            recordName: "trophy2",
            achievementRecordName: "ach2",
            profileRecordName: "hero1",
            familyRecordName: familyName,
            earnedDate: yesterday
        )

        sut.vm.rebuildLists(
            profiles: [hero],
            quests: [],
            logs: [logToday, logYesterday],
            ledgers: [],
            allowancePeriods: [],
            profileAchievements: [trophy1, trophy2],
            achievements: []
        )

        let summary = try #require(sut.vm.weekSummary?.heroSummaries.first)
        #expect(summary.currentStreak == 2)
        #expect(summary.trophiesEarned == 2)
    }

    @Test
    func `rebuildLists differentiates gold and task counts between multiple heroes`() throws {
        let sut = makeSUT()
        let calendar = Calendar.iso8601UTC
        let today = calendar.startOfDay(for: Date())
        let currentWeek = WeekMath.weekOf(date: Date())
        let familyName = "TestFamily"

        let hero1 = ProfileCache(
            recordName: "hero1",
            familyRecordName: familyName,
            displayName: "Hero One",
            role: "hero",
            xpTotal: 100,
            avatarName: nil,
            customAvatarImageData: nil,
            isActive: true,
            level: 5,
            iCloudUserRecordName: "u1",
            avatarClass: nil,
            payoutPolicy: "standard"
        )
        let hero2 = ProfileCache(
            recordName: "hero2",
            familyRecordName: familyName,
            displayName: "Hero Two",
            role: "hero",
            xpTotal: 50,
            avatarName: nil,
            customAvatarImageData: nil,
            isActive: true,
            level: 2,
            iCloudUserRecordName: "u2",
            avatarClass: nil,
            payoutPolicy: "standard"
        )

        let quest1 = QuestCache(
            recordName: "quest1",
            familyRecordName: familyName,
            assigneeRecordName: "hero1",
            templateRecordName: "tmpl1",
            weekOf: currentWeek,
            questName: "Hero 1 Quest",
            isActive: true,
            goldReward: 20.0,
            xpReward: 50,
            rarity: "common",
            scheduleType: "daily",
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: "autoApprove",
            descriptionText: nil,
            createdByRecordName: "parent1"
        )
        let quest2 = QuestCache(
            recordName: "quest2",
            familyRecordName: familyName,
            assigneeRecordName: "hero2",
            templateRecordName: "tmpl2",
            weekOf: currentWeek,
            questName: "Hero 2 Quest",
            isActive: true,
            goldReward: 50.0,
            xpReward: 100,
            rarity: "rare",
            scheduleType: "daily",
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: "autoApprove",
            descriptionText: nil,
            createdByRecordName: "parent1"
        )

        let logHero1 = QuestCompletionCache(
            recordName: "log1",
            questRecordName: "quest1",
            familyRecordName: familyName,
            completerRecordName: "hero1",
            completedDate: today,
            weekOf: currentWeek,
            verificationStatus: VerificationStatus.autoApproved.rawValue,
            approvalMode: ApprovalMode.autoApprove.rawValue,
            verifiedByRecordName: nil,
            verifiedDate: nil
        )

        sut.vm.rebuildLists(
            profiles: [hero1, hero2],
            quests: [quest1, quest2],
            logs: [logHero1],
            ledgers: [],
            allowancePeriods: [],
            profileAchievements: [],
            achievements: []
        )

        let hero1Summary = try #require(sut.vm.weekSummary?.heroSummaries.first(where: { $0.profile.recordName == "hero1" }))
        let hero2Summary = try #require(sut.vm.weekSummary?.heroSummaries.first(where: { $0.profile.recordName == "hero2" }))

        #expect(hero1Summary.weeklyGoldEarned == 20.0)
        #expect(hero2Summary.weeklyGoldEarned == 0.0)
    }

    @Test
    func `rebuildLists does not count multi-target quest as completed when targetCount is not reached`() throws {
        let sut = makeSUT()
        let currentWeek = WeekMath.startOfWeek(for: Date(), payoutDay: .sunday)
        let familyName = "fam1"

        let hero = ProfileCache(
            recordName: "hero1",
            familyRecordName: familyName,
            displayName: "Hero 1",
            role: "hero",
            xpTotal: 100,
            avatarName: "warrior_01",
            customAvatarImageData: nil,
            isActive: true,
            level: 1,
            iCloudUserRecordName: "u1",
            avatarClass: "warrior",
            payoutPolicy: "perQuest"
        )

        let multiTargetQuest = QuestCache(
            recordName: "quest_multi",
            familyRecordName: familyName,
            assigneeRecordName: "hero1",
            templateRecordName: "tmpl_multi",
            weekOf: currentWeek,
            questName: "Multi Task Quest",
            isActive: true,
            goldReward: 20.0,
            xpReward: 50,
            rarity: "common",
            scheduleType: "daily",
            targetCount: 2,
            isAllOrNothing: false,
            approvalMode: "parentVerify",
            descriptionText: nil,
            createdByRecordName: "parent1"
        )

        let log1 = QuestCompletionCache(
            recordName: "log1",
            questRecordName: "quest_multi",
            familyRecordName: familyName,
            completerRecordName: "hero1",
            completedDate: Date(),
            weekOf: currentWeek,
            verificationStatus: VerificationStatus.verified.rawValue,
            approvalMode: ApprovalMode.parentVerify.rawValue,
            verifiedByRecordName: "parent1",
            verifiedDate: Date()
        )

        sut.vm.rebuildLists(
            profiles: [hero],
            quests: [multiTargetQuest],
            logs: [log1],
            ledgers: [],
            allowancePeriods: [],
            profileAchievements: [],
            achievements: []
        )

        let summary = try #require(sut.vm.weekSummary?.heroSummaries.first(where: { $0.profile.recordName == "hero1" }))
        #expect(summary.weeklyQuestsCompleted == 0)
        #expect(summary.weeklyQuestsTotal == 1)
    }

    @Test
    func `realTime hero weekly summary is not labeled pending payout`() throws {
        let sut = makeSUT()
        let calendar = Calendar.iso8601UTC
        let today = calendar.startOfDay(for: Date())
        let currentWeek = WeekMath.startOfWeek(for: Date(), payoutDay: .sunday)
        let familyName = "TestFamily"

        // Create a real-time hero with completed quests
        let realTimeHero = ProfileCache(
            recordName: "hero_rt",
            familyRecordName: familyName,
            displayName: "RealTime Hero",
            role: "hero",
            xpTotal: 50,
            avatarName: nil,
            customAvatarImageData: nil,
            isActive: true,
            level: 3,
            iCloudUserRecordName: "u_rt",
            avatarClass: nil,
            payoutPolicy: "realTime"
        )

        let quest = QuestCache(
            recordName: "quest1",
            familyRecordName: familyName,
            assigneeRecordName: "hero_rt",
            templateRecordName: "tmpl1",
            weekOf: currentWeek,
            questName: "RealTime Quest",
            isActive: true,
            goldReward: 25.0,
            xpReward: 30,
            rarity: "common",
            scheduleType: "daily",
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: "autoApprove",
            descriptionText: nil,
            createdByRecordName: "parent1"
        )

        let log = QuestCompletionCache(
            recordName: "log1",
            questRecordName: "quest1",
            familyRecordName: familyName,
            completerRecordName: "hero_rt",
            completedDate: today,
            weekOf: currentWeek,
            verificationStatus: VerificationStatus.autoApproved.rawValue,
            approvalMode: ApprovalMode.autoApprove.rawValue,
            verifiedByRecordName: nil,
            verifiedDate: nil
        )

        sut.vm.rebuildLists(
            profiles: [realTimeHero],
            quests: [quest],
            logs: [log],
            ledgers: [],
            allowancePeriods: [],
            profileAchievements: [],
            achievements: []
        )

        let summary = try #require(sut.vm.weekSummary)
        // Real-time hero should have earned gold even without a paid period
        #expect(summary.heroSummaries.first?.weeklyGoldEarned ?? 0 > 0)
        // But pendingPayoutAmount must be 0 because real-time heroes have no
        // pending weekly batch — their gold is already settled via rt- entries.
        #expect(summary.pendingPayoutAmount == 0.0)
        // totalEarned still shows the gross amount earned (for display purposes),
        // but the pending amount (what the view uses for "pending" labels) is zero.
        #expect(summary.totalEarned > 0)
        // The view's isPending predicate uses pendingPayoutAmount, not totalEarned.
        // So a real-time hero's summary will show "Real-time Settled" not "Pending Payout".
        let isPending = summary.pendingPayoutAmount > 0
        #expect(isPending == false)
    }

    @Test
    func `mixed realTime and standard heroes use pendingPayoutAmount for non-realTime only`() throws {
        let sut = makeSUT()
        let calendar = Calendar.iso8601UTC
        let today = calendar.startOfDay(for: Date())
        let currentWeek = WeekMath.startOfWeek(for: Date(), payoutDay: .sunday)
        let familyName = "TestFamily"

        let realTimeHero = ProfileCache(
            recordName: "hero_rt",
            familyRecordName: familyName,
            displayName: "RealTime Hero",
            role: "hero",
            xpTotal: 50,
            avatarName: nil,
            customAvatarImageData: nil,
            isActive: true,
            level: 3,
            iCloudUserRecordName: "u_rt",
            avatarClass: nil,
            payoutPolicy: "realTime"
        )

        let standardHero = ProfileCache(
            recordName: "hero_std",
            familyRecordName: familyName,
            displayName: "Standard Hero",
            role: "hero",
            xpTotal: 50,
            avatarName: nil,
            customAvatarImageData: nil,
            isActive: true,
            level: 3,
            iCloudUserRecordName: "u_std",
            avatarClass: nil,
            payoutPolicy: "perQuest"
        )

        let questRT = QuestCache(
            recordName: "quest_rt",
            familyRecordName: familyName,
            assigneeRecordName: "hero_rt",
            templateRecordName: "tmpl_rt",
            weekOf: currentWeek,
            questName: "RT Quest",
            isActive: true,
            goldReward: 50.0,
            xpReward: 30,
            rarity: "common",
            scheduleType: "daily",
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: "autoApprove",
            descriptionText: nil,
            createdByRecordName: "parent1"
        )

        let questStd = QuestCache(
            recordName: "quest_std",
            familyRecordName: familyName,
            assigneeRecordName: "hero_std",
            templateRecordName: "tmpl_std",
            weekOf: currentWeek,
            questName: "Standard Quest",
            isActive: true,
            goldReward: 30.0,
            xpReward: 30,
            rarity: "common",
            scheduleType: "daily",
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: "autoApprove",
            descriptionText: nil,
            createdByRecordName: "parent1"
        )

        let logRT = QuestCompletionCache(
            recordName: "log_rt",
            questRecordName: "quest_rt",
            familyRecordName: familyName,
            completerRecordName: "hero_rt",
            completedDate: today,
            weekOf: currentWeek,
            verificationStatus: VerificationStatus.autoApproved.rawValue,
            approvalMode: ApprovalMode.autoApprove.rawValue,
            verifiedByRecordName: nil,
            verifiedDate: nil
        )

        let logStd = QuestCompletionCache(
            recordName: "log_std",
            questRecordName: "quest_std",
            familyRecordName: familyName,
            completerRecordName: "hero_std",
            completedDate: today,
            weekOf: currentWeek,
            verificationStatus: VerificationStatus.autoApproved.rawValue,
            approvalMode: ApprovalMode.autoApprove.rawValue,
            verifiedByRecordName: nil,
            verifiedDate: nil
        )

        sut.vm.rebuildLists(
            profiles: [realTimeHero, standardHero],
            quests: [questRT, questStd],
            logs: [logRT, logStd],
            ledgers: [],
            allowancePeriods: [],
            profileAchievements: [],
            achievements: []
        )

        let summary = try #require(sut.vm.weekSummary)
        // totalEarned includes both heroes' gold
        #expect(summary.totalEarned == 80.0)
        // pendingPayoutAmount only includes the standard hero
        #expect(summary.pendingPayoutAmount == 30.0)
        // Real-time hero contribution excluded from pending
        #expect(summary.heroSummaries.first(where: { $0.profile.recordName == "hero_rt" })?.weeklyGoldEarned ?? 0 > 0)
        #expect(summary.heroSummaries.first(where: { $0.profile.recordName == "hero_std" })?.weeklyGoldEarned ?? 0 == 30.0)
    }
}
