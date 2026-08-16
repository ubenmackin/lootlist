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

        // Cache-first reads (e.g. FamilyService.fetchHeroes) only serve rows
        // whose cache domain is fresh; without this the hero roster resolves
        // to an empty CloudKit query and parent-only flows no-op.
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

        // Seed paid periods for both candidate payout weeks. The hero is now
        // resolvable by fetchHeroes, so an unseeded previous week would be paid
        // on its due date; seeding both makes the double-run lock the only
        // reason nothing is processed below.
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
        // getOrCreateAllowancePeriod's lookup is cache-first but freshness
        // gated, so stamp the domain for the seeded periods to be honored.
        ctx.cache.markCacheFresh(familyRecordName: ctx.family.id.recordName, type: .allowancePeriod)

        // Process auto-payout
        let count = await ctx.coordinator.processPendingPayoutsIfDue(now: now)

        // Should skip processing because period status is .paid (0 processed)
        #expect(count == 0)
    }

    @Test
    func `realTime heroes are skipped in weekly payout evaluation`() async throws {
        // Seed the hero with a real-time payout policy so the coordinator's
        // weekly payout evaluation skips them entirely.
        let ctx = try setupServices(heroPayoutPolicy: .realTime)

        let now = Date()
        let weekStart = WeekMath.startOfWeek(for: now, payoutDay: .sunday)
        let payoutDate = Calendar.iso8601UTC.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        // Set time to payout day so the guard passes
        let payoutDayDate = Calendar.iso8601UTC.startOfDay(for: payoutDate)

        // No allowance period exists yet; processPendingPayoutsIfDue would normally
        // call getOrCreateAllowancePeriod. A real-time hero should be skipped entirely
        // so no period is created and the count stays 0.
        let count = await ctx.coordinator.processPendingPayoutsIfDue(now: payoutDayDate)

        #expect(count == 0)

        // Verify no allowance period was created for the real-time hero
        let periods = ctx.cache.fetchAllowancePeriods(family: ctx.family.id.recordName)
        #expect(periods.filter { $0.profileRecordName == "hero-1" }.isEmpty)
    }

    @Test
    func `quest sweep deactivates uncompleted past-week quests whose payout was finalized`() async throws {
        let ctx = try setupServices()

        let now = Date()
        let currentWeek = WeekMath.startOfWeek(for: now, payoutDay: .sunday)
        let pastWeek = try #require(Calendar.iso8601UTC.date(byAdding: .day, value: -7, to: currentWeek))

        // Finalize the past week's payout so its quests are legitimately expired.
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

        // Assign a quest for the past week
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

        // Ensure active quest query excludes the swept quest
        let active = try await ctx.questService.fetchActiveQuests(profile: ctx.heroProfile, weekOf: currentWeek)
        #expect(active.isEmpty)
    }

    @Test
    func `quest sweep does not deactivate current-week quests after an early payout`() async throws {
        let ctx = try setupServices()

        let now = Date()
        let currentWeek = WeekMath.startOfWeek(for: now, payoutDay: .sunday)

        // Simulate a mid-week early payout: the current week's period is .paid
        // even though the week is still in progress.
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

        // Assign a quest for the current week (still active mid-week)
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

        // The current week's quests survive even though the week was paid early
        #expect(swept.isEmpty)

        let active = try await ctx.questService.fetchActiveQuests(profile: ctx.heroProfile, weekOf: currentWeek)
        #expect(active.count == 1)
    }

    // MARK: - Weekly Quest Carry-Forward

    /// Seeds a finalized (`.paid`) allowance period for `weekOf` so the expired
    /// quest sweep deactivates that week's quests — the realistic rollover path
    /// the carry-forward engine runs behind.
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

    /// Builds an active quest template + previous-week quest backed by it, then
    /// marks the quest cache fresh so the sweep reads from the cache. Returns the
    /// seeded template for assertions.
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
        // Real-time hero skips the weekly payout loop entirely, isolating the
        // carry-forward path under test.
        let ctx = try setupServices(heroPayoutPolicy: .realTime)

        let currentWeek = WeekMath.startOfWeek(for: Date(), payoutDay: .sunday)
        let pastWeek = try #require(Calendar.iso8601UTC.date(byAdding: .day, value: -7, to: currentWeek))

        seedPaidPeriod(ctx: ctx, weekOf: pastWeek)
        let template = try await seedActiveTemplateAndPastQuest(
            ctx: ctx,
            assignee: ctx.heroProfile.id,
            weekOf: pastWeek
        )

        // `now` is the start of the current week, so the current week's payout
        // day is not yet reached and the carry-forward is the only write.
        _ = await ctx.coordinator.processPendingPayoutsIfDue(now: currentWeek)

        let currentWeekQuests = ctx.cache.fetchQuests(
            family: ctx.family.id.recordName,
            weekInRange: WeekMath.weekRange(starting: currentWeek)
        )

        #expect(currentWeekQuests.count == 1)
        #expect(currentWeekQuests.first?.templateRecordName == template.id.recordName)
        #expect(currentWeekQuests.first?.assigneeRecordName == ctx.heroProfile.id.recordName)

        // A summary toast should be emitted to the parent.
        #expect(ctx.toastManager.toasts.contains { $0.message == "Carried forward 1 quest(s) for the new week." })
    }

    @Test
    func `carry-forward skips inactive Quick Create templates`() async throws {
        let ctx = try setupServices(heroPayoutPolicy: .realTime)

        let currentWeek = WeekMath.startOfWeek(for: Date(), payoutDay: .sunday)
        let pastWeek = try #require(Calendar.iso8601UTC.date(byAdding: .day, value: -7, to: currentWeek))

        seedPaidPeriod(ctx: ctx, weekOf: pastWeek)
        // Ad-hoc Quick Create quests carry an inactive backing template and must
        // not recur into the new week.
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

        // No carry occurred, so no summary toast.
        #expect(!ctx.toastManager.toasts.contains { $0.message.contains("Carried forward") })
    }

    @Test
    func `carry-forward skips templates deleted between weeks`() async throws {
        let ctx = try setupServices(heroPayoutPolicy: .realTime)

        let currentWeek = WeekMath.startOfWeek(for: Date(), payoutDay: .sunday)
        let pastWeek = try #require(Calendar.iso8601UTC.date(byAdding: .day, value: -7, to: currentWeek))

        seedPaidPeriod(ctx: ctx, weekOf: pastWeek)

        // Seed a previous-week quest whose backing template has since been
        // deleted (never upserted into the active template cache).
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

        // Previous-week quest assigned to a profile that is no longer on the
        // family roster (never upserted as a hero). fetchHeroes returns only the
        // seeded hero, so this assignee should be skipped.
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

        // First run carries the quest forward.
        _ = await ctx.coordinator.processPendingPayoutsIfDue(now: currentWeek)

        // Second run in the same week must not duplicate the assignment.
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

        // First run carries the recurring quest into the current week.
        _ = await ctx.coordinator.processPendingPayoutsIfDue(now: currentWeek)

        let carriedQuests = ctx.cache.fetchQuests(
            family: ctx.family.id.recordName,
            weekInRange: WeekMath.weekRange(starting: currentWeek)
        )
        let carried = try #require(carriedQuests.first)
        #expect(carried.templateRecordName == template.id.recordName)
        #expect(carried.assigneeRecordName == ctx.heroProfile.id.recordName)
        #expect(carried.isActive)

        // The parent unassigns the carried-forward quest mid-week. This leaves a
        // suppression tombstone — the row retained with `active == false` —
        // instead of deleting the pair from the current week.
        try await ctx.questService.unassignQuest(carried.toQuest(zoneID: ctx.family.id.zoneID))

        // The quest is gone from the hero's active list immediately.
        let activeAfterUnassign = try await ctx.questService.fetchActiveQuests(profile: ctx.heroProfile, weekOf: currentWeek)
        #expect(activeAfterUnassign.isEmpty)

        // A second run in the same week must NOT re-create the unassigned pair:
        // the previous-week row is still present, but the tombstone occupies the
        // pair in the idempotency gate.
        // The first run already emitted a "Carried forward" toast, so the gate
        // is measured by toast-count growth rather than the message's presence.
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

        // The tombstone itself is retained (inactive) and the second run emits
        // no new carry-forward toast for the suppressed pair.
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
        // A multi-day template (`.specificDays` with `targetCount > 1`) must
        // carry over as a single Quest row that preserves the template's
        // scheduleType + targetCount, since carry-forward passes `nil` overrides
        // to assignQuest so template defaults are used.
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

    // MARK: - Per-Profile Payout-Day Override

    /// Asserts that a hero whose effective payout day differs from the family's
    /// (`.friday` override in a `.sunday` family) gets exactly one current-week
    /// quest carried forward — no duplicates across repeated runs. This is the
    /// regression for the payout-day mismatch: `assignQuest` stores `weekOf`
    /// normalized to the assignee's effective payout day (Saturday for a
    /// `.friday` hero), and the engine must anchor its source window, its
    /// idempotency gate, AND the `weekOf` it writes on that same per-assignee
    /// anchor — otherwise the stored row falls outside the family-anchored gate
    /// and the pair is duplicated on every pass.
    @Test
    func `carry-forward is idempotent for a per-profile payout-day override hero`() async throws {
        let ctx = try setupServices(heroPayoutPolicy: .realTime, heroPayoutDay: .friday)

        // The hero's week is anchored on `.friday` (cycle start = Saturday),
        // which differs from the `.sunday` family cycle (cycle start = Monday).
        let currentWeek = WeekMath.startOfWeek(for: Date(), payoutDay: .friday)
        let pastWeek = try #require(Calendar.iso8601UTC.date(byAdding: .day, value: -7, to: currentWeek))

        seedPaidPeriod(ctx: ctx, weekOf: pastWeek)
        let template = try await seedActiveTemplateAndPastQuest(
            ctx: ctx,
            assignee: ctx.heroProfile.id,
            weekOf: pastWeek
        )

        // First run carries the quest forward into the override hero's week.
        _ = await ctx.coordinator.processPendingPayoutsIfDue(now: currentWeek)

        // Second run in the same week must not duplicate the assignment — the
        // stored current-week row's `weekOf` (assignee-anchored) must fall
        // inside the engine's (now per-assignee-anchored) gate.
        _ = await ctx.coordinator.processPendingPayoutsIfDue(now: currentWeek)

        let currentWeekQuests = ctx.cache.fetchQuests(
            family: ctx.family.id.recordName,
            weekInRange: WeekMath.weekRange(starting: currentWeek)
        )
        let matchingQuests = currentWeekQuests.filter {
            $0.templateRecordName == template.id.recordName && $0.assigneeRecordName == ctx.heroProfile.id.recordName
        }
        #expect(matchingQuests.count == 1)

        // The stored row is binned to the override hero's week (Saturday), which
        // for a `.friday` override sits inside the per-assignee-gated window but
        // outside the family (.sunday) window — the crux of the regression.
        #expect(Calendar.iso8601UTC.startOfDay(for: matchingQuests.first?.weekOf ?? Date()) == Calendar.iso8601UTC.startOfDay(for: currentWeek))
    }

    /// Asserts that a parent's mid-week unassign of a carried-forward quest for
    /// a per-profile payout-day override hero is NOT resurrected on the next
    /// run. This is the regression for the tombstone-visibility gap: the unassign
    /// suppression tombstone is keyed on the assignee-anchored `weekOf`, so the
    /// engine's gate must be anchored on the same per-assignee payout day for the
    /// tombstone to be visible to it.
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

        // First run carries the recurring quest into the override hero's week.
        _ = await ctx.coordinator.processPendingPayoutsIfDue(now: currentWeek)

        let carriedQuests = ctx.cache.fetchQuests(
            family: ctx.family.id.recordName,
            weekInRange: WeekMath.weekRange(starting: currentWeek)
        )
        let carried = try #require(carriedQuests.first)
        #expect(carried.templateRecordName == template.id.recordName)
        #expect(carried.assigneeRecordName == ctx.heroProfile.id.recordName)
        #expect(carried.isActive)

        // The parent unassigns the carried-forward quest mid-week. Because the
        // hero's week is anchored on `.friday`, `isCarryForwardSuppressible`
        // (which day-normalizes against the assignee's effective payout day)
        // still recognizes this as a suppressible carry-window quest and leaves
        // a tombstone rather than hard-deleting the pair.
        try await ctx.questService.unassignQuest(carried.toQuest(zoneID: ctx.family.id.zoneID))

        let activeAfterUnassign = try await ctx.questService.fetchActiveQuests(profile: ctx.heroProfile, weekOf: currentWeek)
        #expect(activeAfterUnassign.isEmpty)

        // A second run in the same week must NOT re-create the unassigned pair:
        // the tombstone occupies the pair in the per-assignee-anchored
        // idempotency gate, same as the default-configuration case.
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

        // The tombstone itself is retained (inactive) and the second run emits
        // no new carry-forward toast for the suppressed pair.
        #expect(afterReRun.count == 1)
        #expect(afterReRun.first?.isActive == false)
        #expect(ctx.toastManager.toasts.count == toastsBeforeReRun)
    }
}
