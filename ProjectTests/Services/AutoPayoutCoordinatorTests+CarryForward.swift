//
//  AutoPayoutCoordinatorTests+CarryForward.swift
//  LootList
//
//  Created by Ben Mackin on 8/9/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing
import UserNotifications

extension AutoPayoutCoordinatorTests {
    // MARK: - Carry-Forward Tests

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

        let unified = ctx.toastManager.toasts.filter { $0.message.hasPrefix("New week ready:") }
        #expect(unified.count == 1)
        #expect(unified.first?.message == "New week ready: 0 payouts settled, 1 old quest retired, 1 quest carried forward.")
        #expect(unified.first?.type == .info)
        #expect(!ctx.toastManager.toasts.contains { $0.message == "Carried forward 1 quest(s) for the new week." })
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
        let unifiedInactive = ctx.toastManager.toasts.filter { $0.message.hasPrefix("New week ready:") }
        #expect(unifiedInactive.count == 1)
        #expect(unifiedInactive.first?.message == "New week ready: 0 payouts settled, 1 old quest retired, 0 quests carried forward.")
        #expect(unifiedInactive.first?.type == .info)
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
            goldReward: 500,
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
        await ctx.cache.upsertQuest(quest)
        _ = try await ctx.cloudKit.save(quest)
        ctx.cache.markCacheFreshForTests(familyRecordName: ctx.family.id.recordName, type: .quest)

        _ = await ctx.coordinator.processPendingPayoutsIfDue(now: currentWeek)

        let currentWeekQuests = ctx.cache.fetchQuests(
            family: ctx.family.id.recordName,
            weekInRange: WeekMath.weekRange(starting: currentWeek)
        )
        #expect(currentWeekQuests.isEmpty)
        #expect(!ctx.toastManager.toasts.contains { $0.message.contains("Carried forward") })
        let unifiedDeleted = ctx.toastManager.toasts.filter { $0.message.hasPrefix("New week ready:") }
        #expect(unifiedDeleted.count == 1)
        #expect(unifiedDeleted.first?.message == "New week ready: 0 payouts settled, 1 old quest retired, 0 quests carried forward.")
        #expect(unifiedDeleted.first?.type == .info)
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
        let unifiedRemoved = ctx.toastManager.toasts.filter { $0.message.hasPrefix("New week ready:") }
        #expect(unifiedRemoved.count == 1)
        #expect(unifiedRemoved.first?.message == "New week ready: 0 payouts settled, 1 old quest retired, 0 quests carried forward.")
        #expect(unifiedRemoved.first?.type == .info)
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
}
