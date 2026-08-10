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
        let cloudKit: CloudKitService
        let cache: CacheService
        let family: Family
        let parentProfile: Profile
        let heroProfile: Profile
    }

    private func setupServices(heroPayoutPolicy: PayoutPolicy = .perQuest) throws -> TestContext {
        let zoneID = CKRecordZone.ID(zoneName: "TestFamily", ownerName: "Owner")
        let cloudKit = CloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        appState.cacheService = cache

        let notification = NotificationService(cloudKit: cloudKit, appState: appState, cacheService: cache)
        let xp = XPService(cloudKit: cloudKit, notificationService: notification, cacheService: cache, appState: appState)
        let treasury = TreasuryService(cloudKit: cloudKit, notificationService: notification, cacheService: cache, appState: appState)
        let quest = QuestService(cloudKit: cloudKit, xpService: xp, notificationService: notification, cacheService: cache, treasuryService: treasury, appState: appState)
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
            id: CKRecord.ID(recordName: "hero-1", zoneID: zoneID)
        )

        appState.currentProfile = parentProfile
        appState.family = familyObj
        appState.familyZoneID = zoneID
        appState.authStatus = .authenticated

        cache.upsertFamily(familyObj)
        cache.upsertProfile(parentProfile)
        cache.upsertProfile(heroProfile)

        let coordinator = AutoPayoutCoordinator(
            treasuryService: treasury,
            questService: quest,
            familyService: family,
            appState: appState
        )

        return TestContext(
            coordinator: coordinator,
            treasury: treasury,
            questService: quest,
            familyService: family,
            appState: appState,
            cloudKit: cloudKit,
            cache: cache,
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

        // Seed an allowance period marked as .paid
        var paidPeriod = AllowancePeriod(
            weekOf: weekStart,
            profile: CKRecord.Reference(recordID: ctx.heroProfile.id, action: .none),
            questsTotal: 2,
            family: CKRecord.Reference(recordID: ctx.family.id, action: .none),
            id: CKRecord.ID(recordName: "period-paid-1", zoneID: ctx.family.id.zoneID)
        )
        paidPeriod.status = .paid
        paidPeriod.totalEarned = 15.0
        paidPeriod.paidAmount = 15.0
        paidPeriod.paidDate = now

        ctx.cache.upsertAllowancePeriod(paidPeriod)

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
}
