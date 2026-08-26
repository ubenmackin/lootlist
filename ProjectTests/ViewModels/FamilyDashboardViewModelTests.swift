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
    private let cloudKit = MockCloudKitService()

    func fetchAllProfilesForFamily(_: Family) async throws -> [Profile] {
        fetchCallCount += 1
        return []
    }

    func refreshProfilesFromCloudKit(for _: Family) async {}

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
    func `zoneReset does not trigger debounced fetch`() async {
        let sut = makeSUT()
        sut.vm.subscribeToSyncEvents(sut.coordinator)

        sut.coordinator.notifyZoneReset()

        await Task.yield()
        // does not touch it, so fetchCallCount stays at 0.
        #expect(sut.fetcher.fetchCallCount == 0)

        sut.vm.unsubscribeFromSyncEvents(sut.coordinator)
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

    @Test
    func `rebuildLists matches hero allowance period with hour offset and zeroes pending earned`() throws {
        let sut = makeSUT()
        let familyName = "fam1"
        let currentWeek = WeekMath.startOfWeek(for: Date(), payoutDay: .sunday)
        let today = Date()

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

        // Allowance period with 6-hour offset (e.g. 06:00 UTC) marked as paid
        let paidPeriod = AllowancePeriodCache(
            recordName: "period_paid",
            profileRecordName: "hero_std",
            familyRecordName: familyName,
            weekOf: currentWeek.addingTimeInterval(6 * 3600),
            status: PayoutStatus.paid.rawValue,
            totalEarned: 30.0,
            questsCompleted: 1,
            questsTotal: 1,
            paidDate: today,
            paidAmount: 30.0
        )

        sut.vm.rebuildLists(
            profiles: [standardHero],
            quests: [questStd],
            logs: [logStd],
            ledgers: [],
            allowancePeriods: [paidPeriod],
            profileAchievements: [],
            achievements: []
        )

        let summary = try #require(sut.vm.weekSummary)
        // Since the period is paid, pendingPayoutAmount must be 0
        #expect(summary.pendingPayoutAmount == 0.0)
        let heroSummary = try #require(summary.heroSummaries.first(where: { $0.profile.recordName == "hero_std" }))
        #expect(heroSummary.weeklyGoldEarned == 0.0)
    }

    // MARK: - Dashboard aggregates

    private func makeHero(_ recordName: String, displayName: String) -> ProfileCache {
        ProfileCache(
            recordName: recordName,
            familyRecordName: "fam1",
            displayName: displayName,
            role: UserRole.hero.rawValue,
            xpTotal: 100,
            avatarName: nil,
            customAvatarImageData: nil,
            isActive: true,
            level: 1,
            iCloudUserRecordName: "u_\(recordName)",
            avatarClass: nil,
            payoutPolicy: PayoutPolicy.perQuest.rawValue
        )
    }

    private func makeParent() -> ProfileCache {
        ProfileCache(
            recordName: "parent1",
            familyRecordName: "fam1",
            displayName: "Dad",
            role: UserRole.guildMaster.rawValue,
            xpTotal: 100,
            avatarName: nil,
            customAvatarImageData: nil,
            isActive: true,
            level: 1,
            iCloudUserRecordName: "u_parent1",
            avatarClass: nil
        )
    }

    @Test
    func `familyOutflow combines every child ledger balance and skips parent rows`() {
        let sut = makeSUT()
        let ava = makeHero("hero1", displayName: "Ava")
        let ben = makeHero("hero2", displayName: "Ben")
        let dad = makeParent()
        let ledgers = [
            LedgerEntryCache(
                recordName: "l_ava_quest", profileRecordName: "hero1", familyRecordName: "fam1",
                amount: 12.25, entryDescription: "Quest reward", date: Date(), source: "quest"
            ),
            LedgerEntryCache(
                recordName: "l_ava_snack", profileRecordName: "hero1", familyRecordName: "fam1",
                amount: -4.00, entryDescription: "Snack", date: Date(), source: "manual"
            ),
            LedgerEntryCache(
                recordName: "l_ben_deposit", profileRecordName: "hero2", familyRecordName: "fam1",
                amount: 8.50, entryDescription: "Deposit", date: Date(), source: "deposit"
            ),
            // Parent wallet rows are not child outflow.
            LedgerEntryCache(
                recordName: "l_dad_wallet", profileRecordName: "parent1", familyRecordName: "fam1",
                amount: 500.00, entryDescription: "Parent wallet", date: Date(), source: "deposit"
            )
        ]

        sut.vm.rebuildLists(
            profiles: [ava, ben, dad],
            quests: [],
            logs: [],
            ledgers: ledgers,
            allowancePeriods: [],
            profileAchievements: [],
            achievements: []
        )

        // 12.25 - 4.00 + 8.50, parent's 500.00 excluded
        #expect(sut.vm.familyOutflow == 16.75)
    }

    @Test
    func `pending review count splits into per-child account cards`() throws {
        let sut = makeSUT()
        let ava = makeHero("hero1", displayName: "Ava")
        let ben = makeHero("hero2", displayName: "Ben")
        let currentWeek = WeekMath.weekOf(date: Date())

        func log(_ name: String, hero: String, status: VerificationStatus) -> QuestCompletionCache {
            QuestCompletionCache(
                recordName: name,
                questRecordName: "quest_\(name)",
                familyRecordName: "fam1",
                completerRecordName: hero,
                completedDate: Date(),
                weekOf: currentWeek,
                verificationStatus: status.rawValue,
                approvalMode: ApprovalMode.autoApprove.rawValue,
                verifiedByRecordName: nil,
                verifiedDate: nil
            )
        }

        let logs = [
            log("p1", hero: "hero1", status: .pending),
            log("p2", hero: "hero1", status: .pending),
            log("a1", hero: "hero1", status: .autoApproved),
            log("p3", hero: "hero2", status: .pending)
        ]
        let ledgers = [
            LedgerEntryCache(
                recordName: "l_ava", profileRecordName: "hero1", familyRecordName: "fam1",
                amount: 10.00, entryDescription: "Quest reward", date: Date(), source: "quest"
            ),
            LedgerEntryCache(
                recordName: "l_ben", profileRecordName: "hero2", familyRecordName: "fam1",
                amount: 2.50, entryDescription: "Deposit", date: Date(), source: "deposit"
            )
        ]

        sut.vm.rebuildLists(
            profiles: [ava, ben],
            quests: [],
            logs: logs,
            ledgers: ledgers,
            allowancePeriods: [],
            profileAchievements: [],
            achievements: []
        )

        #expect(sut.vm.pendingReviewCount == 3)

        // Cards are sorted by display name: Ava before Ben.
        #expect(sut.vm.childAccountCards.map(\.profile.recordName) == ["hero1", "hero2"])

        let avaCard = try #require(sut.vm.childAccountCards.first { $0.profile.recordName == "hero1" })
        #expect(avaCard.balance == 10.00)
        #expect(avaCard.pendingReviewCount == 2)

        let benCard = try #require(sut.vm.childAccountCards.first { $0.profile.recordName == "hero2" })
        #expect(benCard.balance == 2.50)
        #expect(benCard.pendingReviewCount == 1)
    }
}
