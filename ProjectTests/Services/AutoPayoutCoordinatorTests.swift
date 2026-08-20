//
//  AutoPayoutCoordinatorTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/9/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct AutoPayoutCoordinatorTests {
    private struct TestContext {
        let coordinator: AutoPayoutCoordinator
        let treasury: TreasuryService
        let questService: QuestService
        let familyService: FamilyService
        let appState: AppState
        let cloudKit: MockCloudKitService
        let cache: CacheService
        let toastManager: ToastManager
        let family: Family
        let parentProfile: Profile
        let heroProfile: Profile
    }

    private func setupServices(heroPayoutPolicy: PayoutPolicy = .perQuest, heroPayoutDay: PayoutDay? = nil) throws -> TestContext {
        let zoneID = CKRecordZone.ID(zoneName: "TestFamily", ownerName: "Owner")
        let cloudKit = MockCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        appState.cacheService = cache

        let toast = ToastManager()
        let notification = NotificationService(cloudKit: cloudKit, appState: appState, cacheService: cache)
        let xp = XPService(cloudKit: cloudKit, notificationService: notification, cacheService: cache, appState: appState)
        let treasury = TreasuryService(cloudKit: cloudKit, notificationService: notification, cacheService: cache, appState: appState)
        let quest = QuestService(
            cloudKit: cloudKit,
            xpService: xp,
            notificationService: notification,
            cacheService: cache,
            treasuryService: treasury,
            toastManager: toast,
            appState: appState
        )
        let family = FamilyService(cloudKit: cloudKit, appState: appState, questService: quest, cacheService: cache)

        let userRecordID = CKRecord.ID(recordName: "user-1", zoneID: zoneID)
        let familyObj = Family(name: "Dragon Guild", createdBy: userRecordID, payoutDay: .sunday, id: CKRecord.ID(recordName: "family-1", zoneID: zoneID))
        let parentProfile = Profile(
            displayName: "Parent Guildmaster",
            role: .guildMaster,
            iCloudUserID: userRecordID,
            family: CKRecord.Reference(recordID: familyObj.id, action: .none),
            id: CKRecord.ID(recordName: "parent-1", zoneID: zoneID)
        )
        let heroProfile = Profile(
            displayName: "Hero Heroic",
            role: .hero,
            iCloudUserID: userRecordID,
            family: CKRecord.Reference(recordID: familyObj.id, action: .none),
            payoutPolicy: heroPayoutPolicy,
            payoutDay: heroPayoutDay,
            id: CKRecord.ID(recordName: "hero-1", zoneID: zoneID)
        )

        appState.currentProfile = parentProfile
        appState.family = familyObj
        appState.familyZoneID = zoneID
        appState.isZoneOwner = cloudKit.activeIsOwner
        appState.authStatus = .authenticated

        cache.upsertFamily(familyObj)
        cache.upsertProfile(parentProfile)
        cache.upsertProfile(heroProfile)

        cache.markCacheFresh(familyRecordName: familyObj.id.recordName, type: .profile)

        let coordinator = AutoPayoutCoordinator(
            treasuryService: treasury,
            questService: quest,
            familyService: family,
            appState: appState,
            toastManager: toast
        )

        return TestContext(
            coordinator: coordinator,
            treasury: treasury,
            questService: quest,
            familyService: family,
            appState: appState,
            cloudKit: cloudKit,
            cache: cache,
            toastManager: toast,
            family: familyObj,
            parentProfile: parentProfile,
            heroProfile: heroProfile
        )
    }

    @Test
    func `double-run lock prevents re-processing paid allowance period`() async throws {
        let ctx = try setupServices()

        let now = Date()
        let weekStart = WeekMath.startOfWeek(for: now, payoutDay: .sunday)
        let pastWeek = try #require(Calendar.iso8601UTC.date(byAdding: .day, value: -7, to: weekStart))

        for (index, weekOf) in [weekStart, pastWeek].enumerated() {
            var paidPeriod = AllowancePeriod(
                weekOf: weekOf,
                profile: CKRecord.Reference(recordID: ctx.heroProfile.id, action: .none),
                questsTotal: 2,
                family: CKRecord.Reference(recordID: ctx.family.id, action: .none),
                id: CKRecord.ID(recordName: "period-paid-\(index)", zoneID: ctx.family.id.zoneID)
            )
            paidPeriod.status = .paid
            paidPeriod.totalEarned = 15.0
            paidPeriod.paidAmount = 15.0
            paidPeriod.paidDate = now
            ctx.cache.upsertAllowancePeriod(paidPeriod)
        }
        ctx.cache.markCacheFresh(familyRecordName: ctx.family.id.recordName, type: .allowancePeriod)

        let count = await ctx.coordinator.processPendingPayoutsIfDue(now: now)

        #expect(count == 0)
    }

    @Test
    func `realTime heroes are skipped in weekly payout evaluation`() async throws {
        let ctx = try setupServices(heroPayoutPolicy: .realTime)

        let now = Date()
        let weekStart = WeekMath.startOfWeek(for: now, payoutDay: .sunday)
        let payoutDate = Calendar.iso8601UTC.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        let payoutDayDate = Calendar.iso8601UTC.startOfDay(for: payoutDate)

        let count = await ctx.coordinator.processPendingPayoutsIfDue(now: payoutDayDate)

        #expect(count == 0)

        let periods = ctx.cache.fetchAllowancePeriods(family: ctx.family.id.recordName)
        #expect(periods.filter { $0.profileRecordName == "hero-1" }.isEmpty)
    }

    @Test
    func `quest sweep deactivates uncompleted past-week quests whose payout was finalized`() async throws {
        let ctx = try setupServices()

        let now = Date()
        let currentWeek = WeekMath.startOfWeek(for: now, payoutDay: .sunday)
        let pastWeek = try #require(Calendar.iso8601UTC.date(byAdding: .day, value: -7, to: currentWeek))

        var paidPeriod = AllowancePeriod(
            weekOf: pastWeek,
            profile: CKRecord.Reference(recordID: ctx.heroProfile.id, action: .none),
            questsTotal: 1,
            family: CKRecord.Reference(recordID: ctx.family.id, action: .none),
            id: CKRecord.ID(recordName: "period-paid-past", zoneID: ctx.family.id.zoneID)
        )
        paidPeriod.status = .paid
        paidPeriod.totalEarned = 5.0
        paidPeriod.paidAmount = 5.0
        paidPeriod.paidDate = now
        ctx.cache.upsertAllowancePeriod(paidPeriod)

        let template = QuestTemplate(
            name: "Clean Castle",
            description: "Keep room tidy",
            defaultGold: 5.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            createdBy: CKRecord.Reference(recordID: ctx.parentProfile.id, action: .none),
            family: CKRecord.Reference(recordID: ctx.family.id, action: .none),
            id: CKRecord.ID(recordName: "template-1", zoneID: ctx.family.id.zoneID)
        )
        ctx.cache.upsertQuestTemplate(template)

        let pastQuest = Quest(
            template: CKRecord.Reference(recordID: template.id, action: .none),
            assignee: CKRecord.Reference(recordID: ctx.heroProfile.id, action: .none),
            goldReward: 5.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: pastWeek,
            createdBy: CKRecord.Reference(recordID: ctx.parentProfile.id, action: .none),
            family: CKRecord.Reference(recordID: ctx.family.id, action: .none),
            name: "Clean Castle",
            id: CKRecord.ID(recordName: "past-quest-1", zoneID: ctx.family.id.zoneID)
        )
        ctx.cache.upsertQuest(pastQuest)
        _ = try await ctx.cloudKit.save(pastQuest)
        ctx.cache.markCacheFresh(familyRecordName: ctx.family.id.recordName, type: .quest)

        let swept = try await ctx.questService.sweepExpiredQuests(family: ctx.family, currentWeekOf: currentWeek)

        #expect(swept.count == 1)
        #expect(swept.first?.active == false)

        let active = try await ctx.questService.fetchActiveQuests(profile: ctx.heroProfile, weekOf: currentWeek)
        #expect(active.isEmpty)
    }

    @Test
    func `quest sweep does not deactivate current-week quests after an early payout`() async throws {
        let ctx = try setupServices()

        let now = Date()
        let currentWeek = WeekMath.startOfWeek(for: now, payoutDay: .sunday)

        var earlyPaidPeriod = AllowancePeriod(
            weekOf: currentWeek,
            profile: CKRecord.Reference(recordID: ctx.heroProfile.id, action: .none),
            questsTotal: 1,
            family: CKRecord.Reference(recordID: ctx.family.id, action: .none),
            id: CKRecord.ID(recordName: "period-paid-current", zoneID: ctx.family.id.zoneID)
        )
        earlyPaidPeriod.status = .paid
        earlyPaidPeriod.totalEarned = 5.0
        earlyPaidPeriod.paidAmount = 5.0
        earlyPaidPeriod.paidDate = now
        ctx.cache.upsertAllowancePeriod(earlyPaidPeriod)

        let template = QuestTemplate(
            name: "Clean Castle",
            description: "Keep room tidy",
            defaultGold: 5.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            createdBy: CKRecord.Reference(recordID: ctx.parentProfile.id, action: .none),
            family: CKRecord.Reference(recordID: ctx.family.id, action: .none),
            id: CKRecord.ID(recordName: "template-2", zoneID: ctx.family.id.zoneID)
        )
        ctx.cache.upsertQuestTemplate(template)

        let currentQuest = Quest(
            template: CKRecord.Reference(recordID: template.id, action: .none),
            assignee: CKRecord.Reference(recordID: ctx.heroProfile.id, action: .none),
            goldReward: 5.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: currentWeek,
            createdBy: CKRecord.Reference(recordID: ctx.parentProfile.id, action: .none),
            family: CKRecord.Reference(recordID: ctx.family.id, action: .none),
            name: "Clean Castle",
            id: CKRecord.ID(recordName: "current-quest-1", zoneID: ctx.family.id.zoneID)
        )
        ctx.cache.upsertQuest(currentQuest)
        _ = try await ctx.cloudKit.save(currentQuest)
        ctx.cache.markCacheFresh(familyRecordName: ctx.family.id.recordName, type: .quest)

        let swept = try await ctx.questService.sweepExpiredQuests(family: ctx.family, currentWeekOf: currentWeek)

        #expect(swept.isEmpty)

        let active = try await ctx.questService.fetchActiveQuests(profile: ctx.heroProfile, weekOf: currentWeek)
        #expect(active.count == 1)
    }

    private func seedPaidPeriod(ctx: TestContext, weekOf: Date, recordName: String = "period-paid-cf") {
        var period = AllowancePeriod(
            weekOf: weekOf,
            profile: CKRecord.Reference(recordID: ctx.heroProfile.id, action: .none),
            questsTotal: 1,
            family: CKRecord.Reference(recordID: ctx.family.id, action: .none),
            id: CKRecord.ID(recordName: recordName, zoneID: ctx.family.id.zoneID)
        )
        period.status = .paid
        period.totalEarned = 5.0
        period.paidAmount = 5.0
        period.paidDate = weekOf
        ctx.cache.upsertAllowancePeriod(period)
    }

    @discardableResult
    private func seedActiveTemplateAndPastQuest(
        ctx: TestContext,
        templateRecordName: String = "template-cf",
        questRecordName: String = "past-quest-cf",
        templateName: String = "Clean Castle",
        scheduleType: QuestSchedule = .weeklyFlexible,
        specificDays: [String] = [],
        targetCount: Int = 1,
        templateIsActive: Bool = true,
        assignee: CKRecord.ID,
        weekOf: Date
    ) async throws -> QuestTemplate {
        let template = QuestTemplate(
            name: templateName,
            description: "Keep room tidy",
            defaultGold: 5.0,
            xpReward: 50,
            scheduleType: scheduleType,
            specificDays: specificDays,
            targetCount: targetCount,
            createdBy: CKRecord.Reference(recordID: ctx.parentProfile.id, action: .none),
            family: CKRecord.Reference(recordID: ctx.family.id, action: .none),
            isActive: templateIsActive,
            id: CKRecord.ID(recordName: templateRecordName, zoneID: ctx.family.id.zoneID)
        )
        ctx.cache.upsertQuestTemplate(template)

        let quest = Quest(
            template: CKRecord.Reference(recordID: template.id, action: .none),
            assignee: CKRecord.Reference(recordID: assignee, action: .none),
            goldReward: 5.0,
            xpReward: 50,
            scheduleType: scheduleType,
            targetCount: targetCount,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: weekOf,
            createdBy: CKRecord.Reference(recordID: ctx.parentProfile.id, action: .none),
            family: CKRecord.Reference(recordID: ctx.family.id, action: .none),
            name: templateName,
            id: CKRecord.ID(recordName: questRecordName, zoneID: ctx.family.id.zoneID)
        )
        ctx.cache.upsertQuest(quest)
        _ = try await ctx.cloudKit.save(quest)
        ctx.cache.markCacheFresh(familyRecordName: ctx.family.id.recordName, type: .quest)
        return template
    }

    @Test
    func `carry-forward creates new quests for active templates with valid assignees from previous week`() async throws {
        let ctx = try setupServices(heroPayoutPolicy: .realTime)

        let currentWeek = WeekMath.startOfWeek(for: Date(), payoutDay: .sunday)
        let pastWeek = try #require(Calendar.iso8601UTC.date(byAdding: .day, value: -7, to: currentWeek))

        seedPaidPeriod(ctx: ctx, weekOf: pastWeek)
        let template = try await seedActiveTemplateAndPastQuest(
            ctx: ctx,
            assignee: ctx.heroProfile.id,
            weekOf: pastWeek
        )

        _ = await ctx.coordinator.processPendingPayoutsIfDue(now: currentWeek)

        let currentWeekQuests = ctx.cache.fetchQuests(
            family: ctx.family.id.recordName,
            weekInRange: WeekMath.weekRange(starting: currentWeek)
        )

        #expect(currentWeekQuests.count == 1)
        #expect(currentWeekQuests.first?.templateRecordName == template.id.recordName)
        #expect(currentWeekQuests.first?.assigneeRecordName == ctx.heroProfile.id.recordName)

        #expect(ctx.toastManager.toasts.contains { $0.message == "Carried forward 1 quest(s) for the new week." })
    }

    @Test
    func `carry-forward skips inactive Quick Create templates`() async throws {
        let ctx = try setupServices(heroPayoutPolicy: .realTime)

        let currentWeek = WeekMath.startOfWeek(for: Date(), payoutDay: .sunday)
        let pastWeek = try #require(Calendar.iso8601UTC.date(byAdding: .day, value: -7, to: currentWeek))

        seedPaidPeriod(ctx: ctx, weekOf: pastWeek)
        _ = try await seedActiveTemplateAndPastQuest(
            ctx: ctx,
            templateIsActive: false,
            assignee: ctx.heroProfile.id,
            weekOf: pastWeek
        )

        _ = await ctx.coordinator.processPendingPayoutsIfDue(now: currentWeek)

        let currentWeekQuests = ctx.cache.fetchQuests(
            family: ctx.family.id.recordName,
            weekInRange: WeekMath.weekRange(starting: currentWeek)
        )
        #expect(currentWeekQuests.isEmpty)

        #expect(!ctx.toastManager.toasts.contains { $0.message.contains("Carried forward") })
    }

    @Test
    func `carry-forward skips templates deleted between weeks`() async throws {
        let ctx = try setupServices(heroPayoutPolicy: .realTime)

        let currentWeek = WeekMath.startOfWeek(for: Date(), payoutDay: .sunday)
        let pastWeek = try #require(Calendar.iso8601UTC.date(byAdding: .day, value: -7, to: currentWeek))

        seedPaidPeriod(ctx: ctx, weekOf: pastWeek)

        let deletedTemplateID = CKRecord.ID(recordName: "template-deleted", zoneID: ctx.family.id.zoneID)
        let quest = Quest(
            template: CKRecord.Reference(recordID: deletedTemplateID, action: .none),
            assignee: CKRecord.Reference(recordID: ctx.heroProfile.id, action: .none),
            goldReward: 5.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: pastWeek,
            createdBy: CKRecord.Reference(recordID: ctx.parentProfile.id, action: .none),
            family: CKRecord.Reference(recordID: ctx.family.id, action: .none),
            name: "Gone Quest",
            id: CKRecord.ID(recordName: "past-quest-deleted-tmpl", zoneID: ctx.family.id.zoneID)
        )
        ctx.cache.upsertQuest(quest)
        _ = try await ctx.cloudKit.save(quest)
        ctx.cache.markCacheFresh(familyRecordName: ctx.family.id.recordName, type: .quest)

        _ = await ctx.coordinator.processPendingPayoutsIfDue(now: currentWeek)

        let currentWeekQuests = ctx.cache.fetchQuests(
            family: ctx.family.id.recordName,
            weekInRange: WeekMath.weekRange(starting: currentWeek)
        )
        #expect(currentWeekQuests.isEmpty)
        #expect(!ctx.toastManager.toasts.contains { $0.message.contains("Carried forward") })
    }

    @Test
    func `carry-forward skips assignees removed from the family roster`() async throws {
        let ctx = try setupServices(heroPayoutPolicy: .realTime)

        let currentWeek = WeekMath.startOfWeek(for: Date(), payoutDay: .sunday)
        let pastWeek = try #require(Calendar.iso8601UTC.date(byAdding: .day, value: -7, to: currentWeek))

        seedPaidPeriod(ctx: ctx, weekOf: pastWeek)

        let removedAssignee = CKRecord.ID(recordName: "removed-hero-1", zoneID: ctx.family.id.zoneID)
        _ = try await seedActiveTemplateAndPastQuest(
            ctx: ctx,
            assignee: removedAssignee,
            weekOf: pastWeek
        )

        _ = await ctx.coordinator.processPendingPayoutsIfDue(now: currentWeek)

        let currentWeekQuests = ctx.cache.fetchQuests(
            family: ctx.family.id.recordName,
            weekInRange: WeekMath.weekRange(starting: currentWeek)
        )
        #expect(currentWeekQuests.isEmpty)
        #expect(!ctx.toastManager.toasts.contains { $0.message.contains("Carried forward") })
    }

    @Test
    func `carry-forward is idempotent across repeated runs in the same week`() async throws {
        let ctx = try setupServices(heroPayoutPolicy: .realTime)

        let currentWeek = WeekMath.startOfWeek(for: Date(), payoutDay: .sunday)
        let pastWeek = try #require(Calendar.iso8601UTC.date(byAdding: .day, value: -7, to: currentWeek))

        seedPaidPeriod(ctx: ctx, weekOf: pastWeek)
        let template = try await seedActiveTemplateAndPastQuest(
            ctx: ctx,
            assignee: ctx.heroProfile.id,
            weekOf: pastWeek
        )

        _ = await ctx.coordinator.processPendingPayoutsIfDue(now: currentWeek)

        _ = await ctx.coordinator.processPendingPayoutsIfDue(now: currentWeek)

        let currentWeekQuests = ctx.cache.fetchQuests(
            family: ctx.family.id.recordName,
            weekInRange: WeekMath.weekRange(starting: currentWeek)
        )
        let matchingQuests = currentWeekQuests.filter {
            $0.templateRecordName == template.id.recordName && $0.assigneeRecordName == ctx.heroProfile.id.recordName
        }
        #expect(matchingQuests.count == 1)
    }

    @Test
    func `carry-forward does not resurrect a quest the parent unassigned mid-week`() async throws {
        let ctx = try setupServices(heroPayoutPolicy: .realTime)

        let currentWeek = WeekMath.startOfWeek(for: Date(), payoutDay: .sunday)
        let pastWeek = try #require(Calendar.iso8601UTC.date(byAdding: .day, value: -7, to: currentWeek))

        seedPaidPeriod(ctx: ctx, weekOf: pastWeek)
        let template = try await seedActiveTemplateAndPastQuest(
            ctx: ctx,
            assignee: ctx.heroProfile.id,
            weekOf: pastWeek
        )

        _ = await ctx.coordinator.processPendingPayoutsIfDue(now: currentWeek)

        let carriedQuests = ctx.cache.fetchQuests(
            family: ctx.family.id.recordName,
            weekInRange: WeekMath.weekRange(starting: currentWeek)
        )
        let carried = try #require(carriedQuests.first)
        #expect(carried.templateRecordName == template.id.recordName)
        #expect(carried.assigneeRecordName == ctx.heroProfile.id.recordName)
        #expect(carried.isActive)

        try await ctx.questService.unassignQuest(carried.toQuest(zoneID: ctx.family.id.zoneID))

        let activeAfterUnassign = try await ctx.questService.fetchActiveQuests(profile: ctx.heroProfile, weekOf: currentWeek)
        #expect(activeAfterUnassign.isEmpty)

        let toastsBeforeReRun = ctx.toastManager.toasts.count
        _ = await ctx.coordinator.processPendingPayoutsIfDue(now: currentWeek)

        let afterReRun = ctx.cache.fetchQuests(
            family: ctx.family.id.recordName,
            weekInRange: WeekMath.weekRange(starting: currentWeek)
        )
        let resurrected = afterReRun.filter {
            $0.isActive && $0.templateRecordName == template.id.recordName && $0.assigneeRecordName == ctx.heroProfile.id.recordName
        }
        #expect(resurrected.isEmpty)

        #expect(afterReRun.count == 1)
        #expect(afterReRun.first?.isActive == false)
        #expect(ctx.toastManager.toasts.count == toastsBeforeReRun)
    }

    @Test
    func `carry-forward recreates multi-day templates as a single quest preserving schedule and targetCount`() async throws {
        let ctx = try setupServices(heroPayoutPolicy: .realTime)

        let currentWeek = WeekMath.startOfWeek(for: Date(), payoutDay: .sunday)
        let pastWeek = try #require(Calendar.iso8601UTC.date(byAdding: .day, value: -7, to: currentWeek))

        seedPaidPeriod(ctx: ctx, weekOf: pastWeek)
        let template = try await seedActiveTemplateAndPastQuest(
            ctx: ctx,
            templateRecordName: "template-multiday",
            questRecordName: "past-quest-multiday",
            templateName: "Multi-Day Quest",
            scheduleType: .specificDays,
            specificDays: ["monday", "wednesday", "friday"],
            targetCount: 3,
            assignee: ctx.heroProfile.id,
            weekOf: pastWeek
        )

        _ = await ctx.coordinator.processPendingPayoutsIfDue(now: currentWeek)

        let currentWeekQuests = ctx.cache.fetchQuests(
            family: ctx.family.id.recordName,
            weekInRange: WeekMath.weekRange(starting: currentWeek)
        )
        #expect(currentWeekQuests.count == 1)

        let carried = try #require(currentWeekQuests.first)
        #expect(carried.templateRecordName == template.id.recordName)
        #expect(carried.assigneeRecordName == ctx.heroProfile.id.recordName)
        #expect(carried.scheduleTypeEnum == .specificDays)
        #expect(carried.targetCount == 3)
    }

    @Test
    func `carry-forward is idempotent for a per-profile payout-day override hero`() async throws {
        let ctx = try setupServices(heroPayoutPolicy: .realTime, heroPayoutDay: .friday)

        let currentWeek = WeekMath.startOfWeek(for: Date(), payoutDay: .friday)
        let pastWeek = try #require(Calendar.iso8601UTC.date(byAdding: .day, value: -7, to: currentWeek))

        seedPaidPeriod(ctx: ctx, weekOf: pastWeek)
        let template = try await seedActiveTemplateAndPastQuest(
            ctx: ctx,
            assignee: ctx.heroProfile.id,
            weekOf: pastWeek
        )

        _ = await ctx.coordinator.processPendingPayoutsIfDue(now: currentWeek)

        _ = await ctx.coordinator.processPendingPayoutsIfDue(now: currentWeek)

        let currentWeekQuests = ctx.cache.fetchQuests(
            family: ctx.family.id.recordName,
            weekInRange: WeekMath.weekRange(starting: currentWeek)
        )
        let matchingQuests = currentWeekQuests.filter {
            $0.templateRecordName == template.id.recordName && $0.assigneeRecordName == ctx.heroProfile.id.recordName
        }
        #expect(matchingQuests.count == 1)

        #expect(Calendar.iso8601UTC.startOfDay(for: matchingQuests.first?.weekOf ?? Date()) == Calendar.iso8601UTC.startOfDay(for: currentWeek))
    }

    @Test
    func `carry-forward does not resurrect an unassigned quest for a per-profile payout-day override hero`() async throws {
        let ctx = try setupServices(heroPayoutPolicy: .realTime, heroPayoutDay: .friday)

        let currentWeek = WeekMath.startOfWeek(for: Date(), payoutDay: .friday)
        let pastWeek = try #require(Calendar.iso8601UTC.date(byAdding: .day, value: -7, to: currentWeek))

        seedPaidPeriod(ctx: ctx, weekOf: pastWeek)
        let template = try await seedActiveTemplateAndPastQuest(
            ctx: ctx,
            assignee: ctx.heroProfile.id,
            weekOf: pastWeek
        )

        _ = await ctx.coordinator.processPendingPayoutsIfDue(now: currentWeek)

        let carriedQuests = ctx.cache.fetchQuests(
            family: ctx.family.id.recordName,
            weekInRange: WeekMath.weekRange(starting: currentWeek)
        )
        let carried = try #require(carriedQuests.first)
        #expect(carried.templateRecordName == template.id.recordName)
        #expect(carried.assigneeRecordName == ctx.heroProfile.id.recordName)
        #expect(carried.isActive)

        try await ctx.questService.unassignQuest(carried.toQuest(zoneID: ctx.family.id.zoneID))

        let activeAfterUnassign = try await ctx.questService.fetchActiveQuests(profile: ctx.heroProfile, weekOf: currentWeek)
        #expect(activeAfterUnassign.isEmpty)

        let toastsBeforeReRun = ctx.toastManager.toasts.count
        _ = await ctx.coordinator.processPendingPayoutsIfDue(now: currentWeek)

        let afterReRun = ctx.cache.fetchQuests(
            family: ctx.family.id.recordName,
            weekInRange: WeekMath.weekRange(starting: currentWeek)
        )
        let resurrected = afterReRun.filter {
            $0.isActive && $0.templateRecordName == template.id.recordName && $0.assigneeRecordName == ctx.heroProfile.id.recordName
        }
        #expect(resurrected.isEmpty)

        #expect(afterReRun.count == 1)
        #expect(afterReRun.first?.isActive == false)
        #expect(ctx.toastManager.toasts.count == toastsBeforeReRun)
    }

    // MARK: - Half-open week cutoff: payoutDate = weekOf + 6 days

    @Test
    func `weekRange half-open cutoff includes Sunday 23-59 and excludes Monday 00-00`() throws {
        let cal = Calendar.iso8601UTC
        let monday = try #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 3)))
        let weekStart = WeekMath.startOfWeek(for: monday, payoutDay: .sunday)
        #expect(weekStart == cal.startOfDay(for: monday))
        let range = WeekMath.weekRange(starting: weekStart)
        let payoutDate = try #require(cal.date(byAdding: .day, value: AppConstants.Economy.payoutCutoffDayOffset, to: weekStart))
        #expect(payoutDate == cal.date(from: DateComponents(year: 2026, month: 8, day: 9))!)
        #expect(try cal.isDate(payoutDate, inSameDayAs: #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 9)))))

        let sundayNight = try #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 9, hour: 23, minute: 59, second: 59)))
        let nextMonday = try #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 0, minute: 0, second: 0)))

        #expect(range.contains(sundayNight))
        #expect(!range.contains(nextMonday))
        #expect(WeekMath.weekRange(starting: nextMonday).contains(nextMonday))
        #expect(!range.contains(range.upperBound))
        #expect(range.upperBound == nextMonday)
    }

    @Test
    func `payoutDate is weekOf plus 6 days and guard fires at startOfDay`() throws {
        let cal = Calendar.iso8601UTC
        let monday = try #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 3)))
        let weekStart = WeekMath.startOfWeek(for: monday, payoutDay: .sunday)
        let payoutDate = try #require(cal.date(byAdding: .day, value: AppConstants.Economy.payoutCutoffDayOffset, to: weekStart))
        let payoutStart = cal.startOfDay(for: payoutDate)

        let beforePayout = try #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 9, hour: 0, minute: 0, second: 0)))
        let afterMidnight = try #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 9, hour: 12, minute: 0)))
        let justBefore = try #require(cal.date(byAdding: .second, value: -1, to: payoutStart))

        #expect(beforePayout >= payoutStart)
        #expect(afterMidnight >= payoutStart)
        #expect(!(justBefore >= payoutStart))
    }

    @Test
    func `payout cutoff respects payoutDay override with half-open semantics`() throws {
        let cal = Calendar.iso8601UTC
        let fridayWeek = try WeekMath.startOfWeek(for: #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 5))), payoutDay: .friday)
        let range = WeekMath.weekRange(starting: fridayWeek)
        #expect(cal.component(.weekday, from: fridayWeek) == PayoutDay.friday.nextDay.calendarWeekday)
        let lastSecond = fridayWeek.addingTimeInterval(TimeInterval(AppConstants.Time.secondsInWeek - 1))
        let nextStart = fridayWeek.addingTimeInterval(TimeInterval(AppConstants.Time.secondsInWeek))
        #expect(range.contains(lastSecond))
        #expect(!range.contains(nextStart))
        let payoutDate = try #require(cal.date(byAdding: .day, value: AppConstants.Economy.payoutCutoffDayOffset, to: fridayWeek))
        #expect(cal.startOfDay(for: payoutDate) == fridayWeek.addingTimeInterval(TimeInterval(6 * 24 * 3600)))
    }

    @Test
    func `autoPayout coordinator payout window processes due week and skips premature week`() async throws {
        let ctx = try setupServices()

        let cal = Calendar.iso8601UTC
        let monday = try #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 3)))
        let weekStart = WeekMath.startOfWeek(for: monday, payoutDay: .sunday)
        let sundayNoon = try #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 9, hour: 12, minute: 0)))
        let saturdayNoon = try #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 8, hour: 12, minute: 0)))

        let template = QuestTemplate(
            name: "Guild Quest",
            description: "Earn",
            defaultGold: 10.0,
            xpReward: 20,
            scheduleType: .weeklyFlexible,
            createdBy: CKRecord.Reference(recordID: ctx.parentProfile.id, action: .none),
            family: CKRecord.Reference(recordID: ctx.family.id, action: .none),
            id: CKRecord.ID(recordName: "tmpl-payout-cutoff", zoneID: ctx.family.id.zoneID)
        )
        ctx.cache.upsertQuestTemplate(template)
        let quest = Quest(
            template: CKRecord.Reference(recordID: template.id, action: .none),
            assignee: CKRecord.Reference(recordID: ctx.heroProfile.id, action: .none),
            goldReward: 10.0,
            xpReward: 20,
            scheduleType: .weeklyFlexible,
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: weekStart,
            createdBy: CKRecord.Reference(recordID: ctx.parentProfile.id, action: .none),
            family: CKRecord.Reference(recordID: ctx.family.id, action: .none),
            name: "Guild Quest",
            id: CKRecord.ID(recordName: "quest-payout-cutoff", zoneID: ctx.family.id.zoneID)
        )
        ctx.cache.upsertQuest(quest)
        let completion = QuestCompletion(
            quest: CKRecord.Reference(recordID: quest.id, action: .none),
            completedBy: CKRecord.Reference(recordID: ctx.heroProfile.id, action: .none),
            approvalMode: .autoApprove,
            weekOf: weekStart,
            family: CKRecord.Reference(recordID: ctx.family.id, action: .none)
        )
        ctx.cache.upsertQuestCompletion(completion)
        let period = AllowancePeriod(
            weekOf: weekStart,
            profile: CKRecord.Reference(recordID: ctx.heroProfile.id, action: .none),
            questsTotal: 1,
            family: CKRecord.Reference(recordID: ctx.family.id, action: .none),
            id: CKRecord.ID(recordName: "period-payout-cutoff", zoneID: ctx.family.id.zoneID)
        )
        ctx.cache.upsertAllowancePeriod(period)
        ctx.cache.markCacheFresh(familyRecordName: ctx.family.id.recordName, type: .quest)
        ctx.cache.markCacheFresh(familyRecordName: ctx.family.id.recordName, type: .questCompletion)
        ctx.cache.markCacheFresh(familyRecordName: ctx.family.id.recordName, type: .allowancePeriod)

        let nextMondayNoon = try #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 12, minute: 0)))

        let saturdayCount = await ctx.coordinator.processPendingPayoutsIfDue(now: saturdayNoon)
        #expect(saturdayCount == 0)

        let sundayCount = await ctx.coordinator.processPendingPayoutsIfDue(now: sundayNoon)
        #expect(sundayCount == 0)

        let mondayCount = await ctx.coordinator.processPendingPayoutsIfDue(now: nextMondayNoon)
        #expect(mondayCount >= 1)
    }

    @Test
    func `weekRange DST spring-forward still normalizes to midnight UTC`() throws {
        let cal = Calendar.iso8601UTC
        let dstDay = try #require(cal.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 9, minute: 30)))
        let weekStart = WeekMath.startOfWeek(for: dstDay, payoutDay: .sunday)
        let range = WeekMath.weekRange(starting: weekStart)
        let comps = cal.dateComponents([.hour, .minute, .second], from: range.lowerBound)
        #expect(comps.hour == 0)
        #expect(comps.minute == 0)
        #expect(comps.second == 0)
        #expect(range.upperBound == range.lowerBound.addingTimeInterval(TimeInterval(AppConstants.Time.secondsInWeek)))
        #expect(range.contains(dstDay))
    }
}
