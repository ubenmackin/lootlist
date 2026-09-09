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
        let xp = XPService(cloudKit: ck, notificationService: notif, appState: appState)
        xp.cacheService = cache

        let quest = QuestService(cloudKit: ck, xpService: xp, notificationService: notif, appState: appState)
        quest.cacheService = cache

        let family = FamilyService(cloudKit: ck, appState: appState, questService: quest, cacheService: cache)
        let treasury = TreasuryService(cloudKit: ck, notificationService: notif, appState: appState)
        treasury.cacheService = cache
        quest.treasuryService = treasury

        appState.cacheService = cache
        appState.isZoneOwner = ck.activeIsOwner

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

    /// WHY shared cache rows: one source keeps hero/quest/log boilerplate aligned.
    private func makeHeroCache(
        recordName: String,
        displayName: String,
        payoutPolicy: String = "perQuest",
        familyRecordName: String = "fam1",
        iCloudUserRecordName: String? = nil
    ) -> ProfileCache {
        ProfileCache(
            recordName: recordName,
            familyRecordName: familyRecordName,
            displayName: displayName,
            role: "hero",
            xpTotal: 0,
            avatarName: nil,
            customAvatarImageData: nil,
            isActive: true,
            level: 1,
            iCloudUserRecordName: iCloudUserRecordName ?? "u_\(recordName)",
            avatarClass: nil,
            payoutPolicy: payoutPolicy
        )
    }

    /// WHY shared cache rows: one source keeps quest boilerplate aligned.
    private func makeQuestCache(
        recordName: String,
        templateRecordName: String,
        weekOf: Date,
        questName: String,
        goldReward: Int64,
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

    /// WHY shared cache rows: one source keeps completion boilerplate aligned.
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
        let family = ExhaustiveCacheFixtures.sharedFamily(zoneID: zoneID, name: "Guild Matrix Family")
        sut.cache.context?.insert(FamilyCache(from: family))
        _ = sut.cache.saveContext()

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
            achievements: [],
            templates: []
        )

        #expect(vm.heroes.isEmpty)
        #expect(vm.weekSummary?.heroSummaries.isEmpty == true)
        #expect(vm.weekSummary?.totalEarned == 0)
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
            payoutPolicy: "perQuest"
        )
        let hero2 = makeHeroCache(
            recordName: "hero2",
            displayName: "Hero Beta",
            payoutPolicy: "perQuest"
        )
        let hero3 = makeHeroCache(
            recordName: "hero3",
            displayName: "Hero Gamma",
            payoutPolicy: "perQuest"
        )

        let quest1 = makeQuestCache(
            recordName: "q1",
            templateRecordName: "tmpl1",
            weekOf: currentWeek,
            questName: "Clean Room",
            goldReward: 1500,
            xpReward: 30
        )
        let quest2 = makeQuestCache(
            recordName: "q2",
            templateRecordName: "tmpl2",
            weekOf: currentWeek,
            questName: "Slay Dragon",
            goldReward: 5000,
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
            achievements: [],
            templates: []
        )

        #expect(vm.heroes.count == 3)
        let summary1 = try #require(vm.weekSummary?.heroSummaries.first(where: { $0.profile.recordName == "hero1" }))
        let summary2 = try #require(vm.weekSummary?.heroSummaries.first(where: { $0.profile.recordName == "hero2" }))
        let summary3 = try #require(vm.weekSummary?.heroSummaries.first(where: { $0.profile.recordName == "hero3" }))

        #expect(summary1.weeklyGoldEarned == 1500)
        #expect(summary1.weeklyQuestsCompleted == 1)

        #expect(summary2.weeklyGoldEarned == 0)
        #expect(summary2.weeklyQuestsCompleted == 0)

        #expect(summary3.weeklyGoldEarned == 0)
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
                goldReward: 1000,
                xpReward: 20
            )
        ]

        let questsHero2 = [
            makeQuestCache(
                recordName: "q1_h2",
                templateRecordName: "t2",
                weekOf: today,
                questName: "Task A",
                goldReward: 2000,
                xpReward: 40,
                assigneeRecordName: "hero2",
                isAllOrNothing: true
            ),
            makeQuestCache(
                recordName: "q2_h2",
                templateRecordName: "t3",
                weekOf: today,
                questName: "Task B",
                goldReward: 3000,
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

        // WHY perQuest: one completion pays its quest amount.
        let goldHero1 = GoldCalculation.netWeeklyGold(
            quests: questsHero1,
            logs: logs,
            profileRecordName: "hero1",
            payoutPolicy: .perQuest,
            weekRange: weekRange
        )
        #expect(goldHero1 == 10.0)

        // WHY forfeit: partial completion pays nothing under allOrNothing.
        let goldHero2 = GoldCalculation.netWeeklyGold(
            quests: questsHero2,
            logs: logs,
            profileRecordName: "hero2",
            payoutPolicy: .allOrNothing,
            weekRange: weekRange
        )
        #expect(goldHero2 == 0)
    }

    @Test
    func `profile payout policy override precedes family policy`() throws {
        let sut = try makeSUT()
        let zoneID = makeZoneID()
        let calendar = Calendar.iso8601UTC
        let today = calendar.startOfDay(for: Date())
        let weekRange = WeekMath.weekRange(starting: today)

        // WHY override: hero policy wins over family default.
        let family = ExhaustiveCacheFixtures.sharedFamily(zoneID: zoneID, name: "Guild Matrix Family", payoutPolicy: .perQuest)
        sut.cache.context?.insert(FamilyCache(from: family))

        let heroProfile = ExhaustiveCacheFixtures.sharedHero(zoneID: zoneID, displayName: "Override Hero", iCloudRecordName: "hero1", payoutPolicy: .allOrNothing)
        sut.cache.context?.insert(ProfileCache(from: heroProfile))
        _ = sut.cache.saveContext()

        let quests = [
            makeQuestCache(
                recordName: "q1_override",
                templateRecordName: "tmpl1",
                weekOf: today,
                questName: "Override Task 1",
                goldReward: 1000,
                xpReward: 20
            ),
            makeQuestCache(
                recordName: "q2_override",
                templateRecordName: "tmpl2",
                weekOf: today,
                questName: "Override Task 2",
                goldReward: 1000,
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

        // WHY override forfeits: 1-of-2 pays nothing under allOrNothing.
        let overrideGold = GoldCalculation.netWeeklyGold(
            quests: quests,
            logs: oneOfTwoLogs,
            profileRecordName: "hero1",
            payoutPolicy: heroProfile.payoutPolicy,
            weekRange: weekRange
        )
        #expect(overrideGold == 0)

        // WHY family would pay: perQuest rewards the completed quest.
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

        let family = ExhaustiveCacheFixtures.sharedFamily(zoneID: zoneID, name: "Guild Matrix Family")
        let hero = ExhaustiveCacheFixtures.sharedHero(zoneID: zoneID, displayName: "Child Hero", iCloudRecordName: "hero1")
        sut.appState.family = family
        sut.appState.familyZoneID = zoneID
        sut.cloudKit.activeFamilyZoneID = zoneID
        await sut.cache.upsertFamily(family)
        await sut.cache.upsertProfile(hero)
        _ = try await sut.cloudKit.save(family)
        _ = try await sut.cloudKit.save(hero)

        let tmplRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none)
        let quest = Quest(
            template: tmplRef,
            assignee: CKRecord.Reference(recordID: hero.id, action: .none),
            goldReward: 2500,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            approvalMode: .parentVerify,
            weekOf: Date(),
            createdBy: CKRecord.Reference(recordID: family.id, action: .none),
            family: ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID),
            name: "Sweep Floor",
            id: CKRecord.ID(recordName: "quest1", zoneID: zoneID)
        )
        _ = try await sut.cloudKit.save(quest)

        // WHY self-action: session must match the completer.
        sut.appState.currentProfile = hero
        let completion = try await sut.questService.markComplete(quest: quest, by: hero)
        #expect(completion.verificationStatus == .pending)

        // WHY parent-only: verifier must hold a parent role.
        let parent = Profile(
            displayName: "Guild Master",
            avatarClass: .knight,
            avatarPresetID: "warrior_01",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "gm1", zoneID: zoneID),
            family: ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID),
            id: CKRecord.ID(recordName: "gm1", zoneID: zoneID)
        )
        // WHY session is the rejecting guild master.
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
            goldReward: 3000,
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

        // WHY partial forfeits: below targetCount pays nothing.
        let goldPartial = GoldCalculation.netWeeklyGold(
            quests: [quest],
            logs: twoLogs,
            profileRecordName: "hero1",
            payoutPolicy: .allOrNothing,
            weekRange: weekRange
        )
        #expect(goldPartial == 0)

        let threeLogs = twoLogs + [
            makeLog(
                recordName: "l3",
                questRecordName: "multi_q",
                completedDate: today,
                weekOf: today
            )
        ]

        // WHY full earns: matching targetCount pays the whole amount.
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

        let family = ExhaustiveCacheFixtures.sharedFamily(zoneID: zoneID, name: "Guild Matrix Family")
        let hero = ExhaustiveCacheFixtures.sharedHero(zoneID: zoneID, displayName: "Overdraft Hero", iCloudRecordName: "hero1")
        await sut.cache.upsertFamily(family)
        await sut.cache.upsertProfile(hero)
        _ = try await sut.cloudKit.save(family)
        _ = try await sut.cloudKit.save(hero)

        let spendingService = SpendingService(cloudKit: sut.cloudKit, cacheService: sut.cache, appState: sut.appState)
        sut.appState.family = family
        sut.appState.familyZoneID = zoneID
        sut.appState.isZoneOwner = true
        sut.cloudKit.activeFamilyZoneID = zoneID
        sut.cloudKit.activeIsOwner = true
        sut.appState.currentProfile = hero

        _ = try await spendingService.logManual(profile: hero, family: family, familyRecordName: family.id.recordName, description: "Bought Sword", amount: 5000)

        let entries = sut.cache.fetchLedgerEntries(profileRecordName: hero.id.recordName, family: family.id.recordName)
        let balance = entries.reduce(Int64(0)) { $0 + $1.amount }

        #expect(balance == -5000)
    }

    @Test
    func `real time settlement prevents double payment on weekly payout`() async throws {
        let sut = try makeSUT()
        let zoneID = makeZoneID()
        let weekOf = WeekMath.mondayOfWeek(for: Date())
        let goldReward: Int64 = 2500

        let family = ExhaustiveCacheFixtures.sharedFamily(zoneID: zoneID, name: "Guild Matrix Family", payoutPolicy: .realTime)
        let hero = ExhaustiveCacheFixtures.sharedHero(zoneID: zoneID, displayName: "RealTime Hero", iCloudRecordName: "hero1", payoutPolicy: .realTime)
        await sut.cache.upsertFamily(family)
        await sut.cache.upsertProfile(hero)
        _ = try await sut.cloudKit.save(family)
        _ = try await sut.cloudKit.save(hero)

        // WHY cache-first: seed earned quest plus approved completion.
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
        await sut.cache.upsertQuest(quest)
        await sut.cache.upsertQuestCompletions([completion])
        sut.cache.markCacheFreshForTests(familyRecordName: family.id.recordName, type: .quest)
        sut.cache.markCacheFreshForTests(familyRecordName: family.id.recordName, type: .questCompletion)
        sut.cache.markCacheFreshForTests(familyRecordName: family.id.recordName, type: .allowancePeriod)
        sut.cache.markCacheFreshForTests(familyRecordName: family.id.recordName, type: .ledgerEntry)

        // WHY self-settlement: hero settles their own reward.
        sut.appState.family = family
        sut.appState.familyZoneID = zoneID
        sut.appState.isZoneOwner = true
        sut.cloudKit.activeFamilyZoneID = zoneID
        sut.cloudKit.activeIsOwner = true
        sut.appState.currentProfile = hero

        // WHY first settlement pays the earned gold.
        let firstResult = try await sut.treasuryService.processRealTimeSettlement(profile: hero, family: family)
        let first = try #require(firstResult)
        #expect(first.paidAmount == goldReward)

        // WHY idempotency: second settlement must not double pay.
        let secondResult = try await sut.treasuryService.processRealTimeSettlement(profile: hero, family: family)
        let second = try #require(secondResult)
        #expect(second.paidAmount == goldReward)

        // WHY single period: one allowance period per hero week.
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

        let family = ExhaustiveCacheFixtures.sharedFamily(zoneID: zoneID, name: "Guild Matrix Family")
        let hero = ExhaustiveCacheFixtures.sharedHero(zoneID: zoneID, displayName: "Removed Hero", iCloudRecordName: "hero1")
        await sut.cache.upsertFamily(family)
        await sut.cache.upsertProfile(hero)
        sut.cache.markCacheFreshForTests(familyRecordName: family.id.recordName, type: .profile)
        _ = try await sut.cloudKit.save(family)
        _ = try await sut.cloudKit.save(hero)

        // WHY purge check: mock must hold the quest for unassign to find it.
        let quest = Quest(
            template: CKRecord.Reference(recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none),
            assignee: CKRecord.Reference(recordID: hero.id, action: .none),
            goldReward: 1000,
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
        await sut.cache.upsertQuest(quest)
        _ = try await sut.cloudKit.save(quest)

        // WHY unassign guards on the active family being set.
        sut.appState.family = family

        // WHY parent-only: kick requires a parent acting profile.
        sut.appState.currentProfile = Profile(
            displayName: "Guild Master",
            avatarClass: .knight,
            avatarPresetID: "warrior_01",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "gm1", zoneID: zoneID),
            family: ExhaustiveCacheFixtures.sharedFamilyRef(zoneID: zoneID),
            id: CKRecord.ID(recordName: "gm1", zoneID: zoneID)
        )

        // WHY precondition: hero is an active member before the kick.
        let heroesBefore = try await sut.familyService.fetchHeroes(for: family)
        #expect(heroesBefore.contains { $0.id == hero.id })

        try await sut.familyService.kickMember(profile: hero)

        // WHY deactivation: kick must deactivate the cached profile.
        let cachedHero = sut.cache.fetchProfiles(family: family.id.recordName).first { $0.recordName == hero.id.recordName }
        #expect(cachedHero?.isActive == false)

        // WHY roster: kicked hero must leave the active roster.
        let heroesAfter = try await sut.familyService.fetchHeroes(for: family)
        #expect(!heroesAfter.contains { $0.id == hero.id })

        // WHY purge: assigned active quest must leave local cache.
        #expect(sut.cache.fetchQuest(recordName: quest.id.recordName, family: family.id.recordName) == nil)
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
                goldReward: 1000,
                xpReward: 20,
                isAllOrNothing: true
            )
        }

        // WHY forfeit: 3 of 4 under allOrNothing pays nothing.
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
        #expect(goldPartial == 0)

        // WHY full payout: 4 of 4 earns the whole amount.
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
