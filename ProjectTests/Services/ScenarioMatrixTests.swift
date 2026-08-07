//
//  ScenarioMatrixTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/3/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct ScenarioMatrixTests {
    // MARK: - Fixtures & Test Setup

    private struct SUT {
        let cloudKit: MockCloudKitService
        let cache: CacheService
        let questService: QuestService
        let familyService: FamilyService
        let treasuryService: TreasuryService
        let xpService: XPService
        let appState: AppState
    }

    private func makeSUT() throws -> SUT {
        let ck = MockCloudKitService()
        let appState = AppState()
        let cache = try CacheService(inMemory: true)
        let notif = NotificationService(cloudKit: ck, appState: appState, cacheService: cache)
        let xp = XPService(cloudKit: ck, notificationService: notif)
        xp.cacheService = cache

        let quest = QuestService(cloudKit: ck, xpService: xp, notificationService: notif, appState: appState)
        quest.cacheService = cache

        let family = FamilyService(cloudKit: ck, appState: appState, questService: quest, cacheService: cache)
        let treasury = TreasuryService(cloudKit: ck, notificationService: notif, appState: appState)
        treasury.cacheService = cache
        quest.treasuryService = treasury

        appState.cacheService = cache

        return SUT(
            cloudKit: ck,
            cache: cache,
            questService: quest,
            familyService: family,
            treasuryService: treasury,
            xpService: xp,
            appState: appState
        )
    }

    private func makeZoneID() -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "ScenarioZone", ownerName: "ScenarioOwner")
    }

    private func makeFamilyRef(_ zoneID: CKRecordZone.ID) -> CKRecord.Reference {
        CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID),
            action: .none
        )
    }

    private func makeHero(idName: String, displayName: String, zoneID: CKRecordZone.ID, payoutPolicy: PayoutPolicy? = nil) -> Profile {
        let userID = CKRecord.ID(recordName: idName, zoneID: zoneID)
        return Profile(
            displayName: displayName,
            avatarClass: .knight,
            avatarPresetID: "warrior_01",
            role: .hero,
            iCloudUserID: userID,
            family: makeFamilyRef(zoneID),
            payoutPolicy: payoutPolicy ?? .perQuest,
            id: userID
        )
    }

    private func makeFamily(zoneID: CKRecordZone.ID, payoutPolicy: PayoutPolicy = .perQuest) -> Family {
        Family(
            name: "Guild Matrix Family",
            createdBy: CKRecord.ID(recordName: "gm1", zoneID: zoneID),
            payoutPolicy: payoutPolicy,
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
    }

    /// Builds a `ProfileCache` hero row for the shared "fam1" guild with the
    /// boilerplate fields every scenario shares (role "hero", active, no avatar
    /// artwork, perQuest payout) filled in.
    private func makeHeroCache(
        recordName: String,
        displayName: String,
        xpTotal: Int = 0,
        level: Int = 1,
        iCloudUserRecordName: String = "u1",
        avatarClass: String = "warrior",
        payoutPolicy: String = "perQuest"
    ) -> ProfileCache {
        ProfileCache(
            recordName: recordName,
            familyRecordName: "fam1",
            displayName: displayName,
            role: "hero",
            xpTotal: xpTotal,
            avatarName: nil,
            customAvatarImageData: nil,
            isActive: true,
            level: level,
            iCloudUserRecordName: iCloudUserRecordName,
            avatarClass: avatarClass,
            payoutPolicy: payoutPolicy
        )
    }

    /// Builds a `QuestCache` row for the shared "fam1" guild with the boilerplate
    /// fields every scenario shares (active, no description, autoApprove, gm1
    /// creator) filled in.
    private func makeQuestCache(
        recordName: String,
        templateRecordName: String,
        weekOf: Date,
        questName: String,
        goldReward: Double,
        xpReward: Int,
        assigneeRecordName: String = "hero1",
        rarity: String = "common",
        scheduleType: String = "daily",
        targetCount: Int = 1,
        isAllOrNothing: Bool = false,
        approvalMode: String = "autoApprove",
        familyRecordName: String = "fam1",
        createdByRecordName: String = "gm1"
    ) -> QuestCache {
        QuestCache(
            recordName: recordName,
            familyRecordName: familyRecordName,
            assigneeRecordName: assigneeRecordName,
            templateRecordName: templateRecordName,
            weekOf: weekOf,
            questName: questName,
            isActive: true,
            goldReward: goldReward,
            xpReward: xpReward,
            rarity: rarity,
            scheduleType: scheduleType,
            targetCount: targetCount,
            isAllOrNothing: isAllOrNothing,
            approvalMode: approvalMode,
            descriptionText: nil,
            createdByRecordName: createdByRecordName
        )
    }

    /// Builds a `QuestCompletionCache` row for the shared "fam1" guild with the
    /// boilerplate fields every scenario shares (auto-approved, no verification
    /// stamps) filled in.
    private func makeLog(
        recordName: String,
        questRecordName: String,
        completerRecordName: String = "hero1",
        completedDate: Date,
        weekOf: Date,
        familyRecordName: String = "fam1"
    ) -> QuestCompletionCache {
        QuestCompletionCache(
            recordName: recordName,
            questRecordName: questRecordName,
            familyRecordName: familyRecordName,
            completerRecordName: completerRecordName,
            completedDate: completedDate,
            weekOf: weekOf,
            verificationStatus: VerificationStatus.autoApproved.rawValue,
            approvalMode: ApprovalMode.autoApprove.rawValue,
            verifiedByRecordName: nil,
            verifiedDate: nil
        )
    }

    // MARK: - 1. Guild Hero Count Matrix

    @Test
    func `empty guild master has zero hero summaries and safe defaults`() throws {
        let sut = try makeSUT()
        let zoneID = makeZoneID()
        let family = makeFamily(zoneID: zoneID)
        sut.cache.upsertFamily(family)

        let vm = FamilyDashboardViewModel(
            questService: sut.questService,
            treasury: sut.treasuryService,
            achievementService: AchievementService(cloudKit: sut.cloudKit),
            familyService: sut.familyService,
            appState: sut.appState
        )

        vm.rebuildLists(
            profiles: [],
            quests: [],
            logs: [],
            ledgers: [],
            allowancePeriods: [],
            profileAchievements: [],
            achievements: []
        )

        #expect(vm.heroes.isEmpty)
        #expect(vm.weekSummary?.heroSummaries.isEmpty == true)
        #expect(vm.weekSummary?.totalEarned == 0.0)
        #expect(vm.weekSummary?.totalQuestsCompleted == 0)
    }

    @Test
    func `multi hero guild with three heroes isolates XP and gold`() throws {
        let sut = try makeSUT()
        let calendar = Calendar.iso8601UTC
        let today = calendar.startOfDay(for: Date())
        let currentWeek = WeekMath.weekOf(date: Date())

        let hero1 = makeHeroCache(
            recordName: "hero1",
            displayName: "Hero Alpha",
            xpTotal: 150,
            level: 3,
            iCloudUserRecordName: "u1",
            avatarClass: "warrior"
        )
        let hero2 = makeHeroCache(
            recordName: "hero2",
            displayName: "Hero Beta",
            xpTotal: 300,
            level: 5,
            iCloudUserRecordName: "u2",
            avatarClass: "mage"
        )
        let hero3 = makeHeroCache(
            recordName: "hero3",
            displayName: "Hero Gamma",
            iCloudUserRecordName: "u3",
            avatarClass: "rogue"
        )

        let quest1 = makeQuestCache(
            recordName: "q1",
            templateRecordName: "tmpl1",
            weekOf: currentWeek,
            questName: "Clean Room",
            goldReward: 15.0,
            xpReward: 30
        )
        let quest2 = makeQuestCache(
            recordName: "q2",
            templateRecordName: "tmpl2",
            weekOf: currentWeek,
            questName: "Slay Dragon",
            goldReward: 50.0,
            xpReward: 100,
            assigneeRecordName: "hero2",
            rarity: "rare"
        )

        let log1 = makeLog(
            recordName: "log1",
            questRecordName: "q1",
            completedDate: today,
            weekOf: currentWeek
        )

        let vm = FamilyDashboardViewModel(
            questService: sut.questService,
            treasury: sut.treasuryService,
            achievementService: AchievementService(cloudKit: sut.cloudKit),
            familyService: sut.familyService,
            appState: sut.appState
        )

        vm.rebuildLists(
            profiles: [hero1, hero2, hero3],
            quests: [quest1, quest2],
            logs: [log1],
            ledgers: [],
            allowancePeriods: [],
            profileAchievements: [],
            achievements: []
        )

        #expect(vm.heroes.count == 3)
        let summary1 = try #require(vm.weekSummary?.heroSummaries.first(where: { $0.profile.recordName == "hero1" }))
        let summary2 = try #require(vm.weekSummary?.heroSummaries.first(where: { $0.profile.recordName == "hero2" }))
        let summary3 = try #require(vm.weekSummary?.heroSummaries.first(where: { $0.profile.recordName == "hero3" }))

        #expect(summary1.weeklyGoldEarned == 15.0)
        #expect(summary1.weeklyQuestsCompleted == 1)

        #expect(summary2.weeklyGoldEarned == 0.0)
        #expect(summary2.weeklyQuestsCompleted == 0)

        #expect(summary3.weeklyGoldEarned == 0.0)
        #expect(summary3.weeklyQuestsCompleted == 0)
    }

    // MARK: - 2. Payout Policy Matrix

    @Test
    func `mixed payout policies in same family calculates correct per hero totals`() {
        let calendar = Calendar.iso8601UTC
        let today = calendar.startOfDay(for: Date())
        let weekRange = WeekMath.weekRange(starting: today)

        let questsHero1 = [
            makeQuestCache(
                recordName: "q1_h1",
                templateRecordName: "t1",
                weekOf: today,
                questName: "Task 1",
                goldReward: 10.0,
                xpReward: 20
            )
        ]

        let questsHero2 = [
            makeQuestCache(
                recordName: "q1_h2",
                templateRecordName: "t2",
                weekOf: today,
                questName: "Task A",
                goldReward: 20.0,
                xpReward: 40,
                assigneeRecordName: "hero2",
                isAllOrNothing: true
            ),
            makeQuestCache(
                recordName: "q2_h2",
                templateRecordName: "t3",
                weekOf: today,
                questName: "Task B",
                goldReward: 30.0,
                xpReward: 60,
                assigneeRecordName: "hero2",
                rarity: "rare",
                isAllOrNothing: true
            )
        ]

        let logs = [
            makeLog(
                recordName: "log_h1",
                questRecordName: "q1_h1",
                completedDate: today,
                weekOf: today
            ),
            makeLog(
                recordName: "log_h2",
                questRecordName: "q1_h2",
                completerRecordName: "hero2",
                completedDate: today,
                weekOf: today
            )
        ]

        // Hero 1 has perQuest policy: earns 10.0 for completed q1_h1
        let goldHero1 = GoldCalculation.netWeeklyGold(
            quests: questsHero1,
            logs: logs,
            profileRecordName: "hero1",
            payoutPolicy: .perQuest,
            weekRange: weekRange
        )
        #expect(goldHero1 == 10.0)

        // Hero 2 has allOrNothing policy: completed 1 of 2 assigned quests -> forfeits all gold
        let goldHero2 = GoldCalculation.netWeeklyGold(
            quests: questsHero2,
            logs: logs,
            profileRecordName: "hero2",
            payoutPolicy: .allOrNothing,
            weekRange: weekRange
        )
        #expect(goldHero2 == 0.0)
    }

    @Test
    func `profile payout policy override precedes family policy`() throws {
        let sut = try makeSUT()
        let zoneID = makeZoneID()
        let calendar = Calendar.iso8601UTC
        let today = calendar.startOfDay(for: Date())
        let weekRange = WeekMath.weekRange(starting: today)

        // Family defaults to perQuest; the hero overrides with allOrNothing.
        let family = makeFamily(zoneID: zoneID, payoutPolicy: .perQuest)
        sut.cache.upsertFamily(family)

        let heroProfile = makeHero(idName: "hero1", displayName: "Override Hero", zoneID: zoneID, payoutPolicy: .allOrNothing)
        sut.cache.upsertProfile(heroProfile)

        let quests = [
            makeQuestCache(
                recordName: "q1_override",
                templateRecordName: "tmpl1",
                weekOf: today,
                questName: "Override Task 1",
                goldReward: 10.0,
                xpReward: 20
            ),
            makeQuestCache(
                recordName: "q2_override",
                templateRecordName: "tmpl2",
                weekOf: today,
                questName: "Override Task 2",
                goldReward: 10.0,
                xpReward: 20
            )
        ]

        let oneOfTwoLogs = [
            makeLog(
                recordName: "log_override_1",
                questRecordName: "q1_override",
                completedDate: today,
                weekOf: today
            )
        ]

        // The hero's allOrNothing override forfeits gold at 1-of-2 completions...
        let overrideGold = GoldCalculation.netWeeklyGold(
            quests: quests,
            logs: oneOfTwoLogs,
            profileRecordName: "hero1",
            payoutPolicy: heroProfile.payoutPolicy,
            weekRange: weekRange
        )
        #expect(overrideGold == 0.0)

        // ...where the family's perQuest policy would have paid the completed quest.
        let familyPolicyGold = GoldCalculation.netWeeklyGold(
            quests: quests,
            logs: oneOfTwoLogs,
            profileRecordName: "hero1",
            payoutPolicy: family.payoutPolicy,
            weekRange: weekRange
        )
        #expect(familyPolicyGold == 10.0)
    }

    // MARK: - 3. Quest Approval & Rejection Matrix

    @Test
    func `parent rejection reverts pending status and withholds reward`() async throws {
        let sut = try makeSUT()
        let zoneID = makeZoneID()

        let family = makeFamily(zoneID: zoneID)
        let hero = makeHero(idName: "hero1", displayName: "Child Hero", zoneID: zoneID)
        sut.cache.upsertFamily(family)
        sut.cache.upsertProfile(hero)
        _ = try await sut.cloudKit.save(family)
        _ = try await sut.cloudKit.save(hero)

        let tmplRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none)
        let quest = Quest(
            template: tmplRef,
            assignee: CKRecord.Reference(recordID: hero.id, action: .none),
            goldReward: 25.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            approvalMode: .parentVerify,
            weekOf: Date(),
            createdBy: CKRecord.Reference(recordID: family.id, action: .none),
            family: makeFamilyRef(zoneID),
            name: "Sweep Floor"
        )
        _ = try await sut.cloudKit.save(quest)

        // markComplete is a hero self-action — the acting session must match
        // the completer's identity.
        sut.appState.currentProfile = hero
        let completion = try await sut.questService.markComplete(quest: quest, by: hero)
        #expect(completion.verificationStatus == .pending)

        // Rejection is parent-only at the service layer, so the acting profile
        // passed as the verifier must be a parent (Guild Master / Ranger).
        let parent = Profile(
            displayName: "Guild Master",
            avatarClass: .knight,
            avatarPresetID: "warrior_01",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "gm1", zoneID: zoneID),
            family: makeFamilyRef(zoneID),
            id: CKRecord.ID(recordName: "gm1", zoneID: zoneID)
        )
        // The authenticated session is the guild master performing the reject.
        sut.appState.currentProfile = parent
        let rejected = try await sut.questService.reject(questLog: completion, by: parent)
        #expect(rejected.verificationStatus == .rejected)

        let freshHero = try await sut.cloudKit.fetch(Profile.self, id: hero.id)
        #expect(freshHero.xp == 0)
    }

    @Test
    func `multi target quest requires exact target count for completion`() {
        let calendar = Calendar.iso8601UTC
        let today = calendar.startOfDay(for: Date())
        let weekRange = WeekMath.weekRange(starting: today)

        let quest = makeQuestCache(
            recordName: "multi_q",
            templateRecordName: "tmpl1",
            weekOf: today,
            questName: "Read 3 Books",
            goldReward: 30.0,
            xpReward: 60,
            scheduleType: "weekly",
            targetCount: 3,
            isAllOrNothing: true
        )

        let twoLogs = [
            makeLog(
                recordName: "l1",
                questRecordName: "multi_q",
                completedDate: today,
                weekOf: today
            ),
            makeLog(
                recordName: "l2",
                questRecordName: "multi_q",
                completedDate: today,
                weekOf: today
            )
        ]

        // Under allOrNothing with targetCount=3, 2 completions is not fully completed -> 0 gold
        let goldPartial = GoldCalculation.netWeeklyGold(
            quests: [quest],
            logs: twoLogs,
            profileRecordName: "hero1",
            payoutPolicy: .allOrNothing,
            weekRange: weekRange
        )
        #expect(goldPartial == 0.0)

        let threeLogs = twoLogs + [
            makeLog(
                recordName: "l3",
                questRecordName: "multi_q",
                completedDate: today,
                weekOf: today
            )
        ]

        // With 3 completions matching targetCount=3 -> full 30.0 gold earned
        let goldFull = GoldCalculation.netWeeklyGold(
            quests: [quest],
            logs: threeLogs,
            profileRecordName: "hero1",
            payoutPolicy: .allOrNothing,
            weekRange: weekRange
        )
        #expect(goldFull == 30.0)
    }

    // MARK: - 4. Treasury & Settlement Matrix

    @Test
    func `treasury spending exceeding balance allows overdraft with correct negative balance`() async throws {
        let sut = try makeSUT()
        let zoneID = makeZoneID()

        let family = makeFamily(zoneID: zoneID)
        let hero = makeHero(idName: "hero1", displayName: "Overdraft Hero", zoneID: zoneID)
        sut.cache.upsertFamily(family)
        sut.cache.upsertProfile(hero)
        _ = try await sut.cloudKit.save(family)
        _ = try await sut.cloudKit.save(hero)

        let spendingService = ManualSpendingService(cloudKit: sut.cloudKit, cacheService: sut.cache, appState: sut.appState)
        sut.appState.currentProfile = hero

        _ = try await spendingService.logManual(profile: hero, family: family, familyRecordName: family.id.recordName, description: "Bought Sword", amount: 50.0)

        let entries = sut.cache.fetchLedgerEntries(profileRecordName: hero.id.recordName)
        let balance = entries.reduce(0.0) { $0 + $1.amount }

        #expect(balance == -50.0)
    }

    @Test
    func `real time settlement prevents double payment on weekly payout`() async throws {
        let sut = try makeSUT()
        let zoneID = makeZoneID()
        let weekOf = WeekMath.mondayOfWeek(for: Date())
        let goldReward = 25.0

        let family = makeFamily(zoneID: zoneID, payoutPolicy: .realTime)
        let hero = makeHero(idName: "hero1", displayName: "RealTime Hero", zoneID: zoneID, payoutPolicy: .realTime)
        sut.cache.upsertFamily(family)
        sut.cache.upsertProfile(hero)
        _ = try await sut.cloudKit.save(family)
        _ = try await sut.cloudKit.save(hero)

        // Seed an earned quest + approved completion (cache-first pattern from
        // SettlementScaffold.seedEarned).
        let quest = Quest(
            template: CKRecord.Reference(recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none),
            assignee: CKRecord.Reference(recordID: hero.id, action: .none),
            goldReward: goldReward,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: weekOf,
            createdBy: CKRecord.Reference(recordID: family.id, action: .none),
            family: CKRecord.Reference(recordID: family.id, action: .none),
            name: "RealTime Quest",
            id: CKRecord.ID(recordName: "quest_rt", zoneID: zoneID)
        )
        let completion = QuestCompletion(
            quest: CKRecord.Reference(recordID: quest.id, action: .none),
            completedBy: CKRecord.Reference(recordID: hero.id, action: .none),
            approvalMode: .autoApprove,
            completedDate: weekOf,
            weekOf: weekOf,
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: "log_rt", zoneID: zoneID)
        )
        sut.cache.upsertQuest(quest)
        sut.cache.upsertQuestCompletions([completion])
        sut.cache.markCacheFresh(familyRecordName: family.id.recordName, type: .questCompletion)

        // Real-time settlement is a self-action — the hero settles their own
        // reward, so the acting profile must match the target.
        sut.appState.currentProfile = hero

        // First settlement pays out the earned gold...
        let firstResult = try await sut.treasuryService.processRealTimeSettlement(profile: hero, family: family)
        let first = try #require(firstResult)
        #expect(first.paidAmount == goldReward)

        // ...and a second settlement must not double it.
        let secondResult = try await sut.treasuryService.processRealTimeSettlement(profile: hero, family: family)
        let second = try #require(secondResult)
        #expect(second.paidAmount == goldReward)

        // Exactly one allowance period exists for the hero's week.
        let periods = await sut.treasuryService.fetchAllowancePeriods(family: family)
        #expect(periods.count == 1)
    }

    // MARK: - 5. Membership & Policy Edge Cases

    @Test
    func `guild master removing hero purges or orphans hero data correctly`() async throws {
        let sut = try makeSUT()
        let zoneID = makeZoneID()
        sut.cloudKit.activeFamilyZoneID = zoneID
        let weekOf = WeekMath.weekOf(date: Date())

        let family = makeFamily(zoneID: zoneID)
        let hero = makeHero(idName: "hero1", displayName: "Removed Hero", zoneID: zoneID)
        sut.cache.upsertFamily(family)
        sut.cache.upsertProfile(hero)
        _ = try await sut.cloudKit.save(family)
        _ = try await sut.cloudKit.save(hero)

        // An active quest assigned to the hero, persisted to the CloudKit mock
        // so unassignActiveQuests can find and purge it.
        let quest = Quest(
            template: CKRecord.Reference(recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none),
            assignee: CKRecord.Reference(recordID: hero.id, action: .none),
            goldReward: 10.0,
            xpReward: 20,
            scheduleType: .weeklyFlexible,
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: weekOf,
            createdBy: CKRecord.Reference(recordID: family.id, action: .none),
            family: CKRecord.Reference(recordID: family.id, action: .none),
            name: "Remove Quest",
            id: CKRecord.ID(recordName: "quest_removed", zoneID: zoneID)
        )
        _ = try await sut.cloudKit.save(quest)

        // unassignActiveQuests guards on appState.family being set.
        sut.appState.family = family

        // The acting profile must be a parent for the service-layer
        // authorization guard to let the kick proceed.
        sut.appState.currentProfile = Profile(
            displayName: "Guild Master",
            avatarClass: .knight,
            avatarPresetID: "warrior_01",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "gm1", zoneID: zoneID),
            family: makeFamilyRef(zoneID),
            id: CKRecord.ID(recordName: "gm1", zoneID: zoneID)
        )

        // Sanity: the hero is an active roster member before the kick.
        let heroesBefore = try await sut.familyService.fetchHeroes(for: family)
        #expect(heroesBefore.contains { $0.id == hero.id })

        try await sut.familyService.kickMember(profile: hero)

        // (a) The hero's profile is deactivated.
        let freshHero = try await sut.cloudKit.fetch(Profile.self, id: hero.id)
        #expect(freshHero.isActive == false)

        // (b) The family roster no longer includes the hero as an active member.
        let heroesAfter = try await sut.familyService.fetchHeroes(for: family)
        #expect(!heroesAfter.contains { $0.id == hero.id })

        // (c) The active quest assigned to the hero was purged from CloudKit:
        // unassignActiveQuests deletes the quest record, so fetching it now must
        // throw rather than return a ghost record.
        await #expect(throws: CloudKitServiceError.self) {
            _ = try await sut.cloudKit.fetch(Quest.self, id: quest.id)
        }
    }

    @Test
    func `all or nothing policy forfeits gold when three of four quests completed`() {
        let calendar = Calendar.iso8601UTC
        let today = calendar.startOfDay(for: Date())
        let weekRange = WeekMath.weekRange(starting: today)

        let quests = (1 ... 4).map { index in
            makeQuestCache(
                recordName: "aon_q\(index)",
                templateRecordName: "tmpl\(index)",
                weekOf: today,
                questName: "All-or-Nothing Quest \(index)",
                goldReward: 10.0,
                xpReward: 20,
                isAllOrNothing: true
            )
        }

        // 3 of 4 completed quests under allOrNothing -> full forfeit.
        let threeLogs = [
            makeLog(recordName: "aon_log_1", questRecordName: "aon_q1", completedDate: today, weekOf: today),
            makeLog(recordName: "aon_log_2", questRecordName: "aon_q2", completedDate: today, weekOf: today),
            makeLog(recordName: "aon_log_3", questRecordName: "aon_q3", completedDate: today, weekOf: today)
        ]
        let goldPartial = GoldCalculation.netWeeklyGold(
            quests: quests,
            logs: threeLogs,
            profileRecordName: "hero1",
            payoutPolicy: .allOrNothing,
            weekRange: weekRange
        )
        #expect(goldPartial == 0.0)

        // 4 of 4 completed quests -> full 40.0 payout.
        let fourLogs = threeLogs + [makeLog(recordName: "aon_log_4", questRecordName: "aon_q4", completedDate: today, weekOf: today)]
        let goldFull = GoldCalculation.netWeeklyGold(
            quests: quests,
            logs: fourLogs,
            profileRecordName: "hero1",
            payoutPolicy: .allOrNothing,
            weekRange: weekRange
        )
        #expect(goldFull == 40.0)
    }
}
