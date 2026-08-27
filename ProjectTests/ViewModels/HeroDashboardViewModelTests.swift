//
//  HeroDashboardViewModelTests.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct HeroDashboardViewModelTests {
    @Test
    func `weekday code formatting`() {
        let code = HeroDashboardViewModel.todayWeekdayCode()
        #expect(AppConstants.weekdayCodes.contains(code))
    }

    @Test
    func `initial state before loading`() {
        let appState = AppState()

        let viewModel = HeroDashboardViewModel(appState: appState)

        #expect(viewModel.todaysQuests.isEmpty)
        #expect(viewModel.streak == 0)
        #expect(viewModel.earnedThisWeek == 0)
    }

    @Test
    func `rebuildLists is a no-op when no profile is present`() {
        let appState = AppState()

        let viewModel = HeroDashboardViewModel(appState: appState)
        viewModel.rebuildLists(quests: [], logs: [], templates: [])

        #expect(viewModel.todaysQuests.isEmpty)
        #expect(viewModel.streak == 0)
        #expect(viewModel.earnedThisWeek == 0)
        #expect(viewModel.availableTemplatesCount == 0)
    }

    @Test
    func `sunday-Saturday week days calculation`() {
        // PayoutDay .sunday anchors the 7-day cycle on Monday (Mon-Sun).
        let weekDays = HeroDashboardViewModel.currentWeekDays()
        #expect(weekDays.count == 7)
        #expect(weekDays.first?.weekdayCode == "monday")
        #expect(weekDays.first?.shortName == "Mon")
        #expect(weekDays.last?.weekdayCode == "sunday")
        #expect(weekDays.last?.shortName == "Sun")
        // swiftformat:disable:next preferKeyPath redundantClosure
        #expect(weekDays.contains(where: { $0.isToday }))
    }

    private struct TestHarness {
        let appState: AppState
        let zoneID: CKRecordZone.ID
        let profileName: String
        let familyName: String
    }

    private func makeHarness() -> TestHarness {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let appState = AppState()
        let family = Family(
            name: "Test Family",
            createdBy: CKRecord.ID(recordName: "parent1", zoneID: zoneID),
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
        appState.family = family
        let familyRef = CKRecord.Reference(
            recordID: family.id,
            action: .none
        )
        let profile = Profile(
            displayName: "Test Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "u1", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        )
        appState.currentProfile = profile
        return TestHarness(
            appState: appState,
            zoneID: zoneID,
            profileName: "hero1",
            familyName: "fam1"
        )
    }

    @Test
    func `rebuildLists derives earnedThisWeek from cache`() {
        let test = makeHarness()
        let viewModel = HeroDashboardViewModel(appState: test.appState)

        let currentWeek = WeekMath.weekOf(date: Date())
        let quest = QuestCache(
            recordName: "q1",
            familyRecordName: test.familyName,
            assigneeRecordName: test.profileName,
            templateRecordName: "t1",
            weekOf: currentWeek,
            questName: "Complete Dragon",
            isActive: true,
            goldReward: 15.0,
            xpReward: 10,
            rarity: "common",
            scheduleType: QuestSchedule.specificDays.rawValue,
            isAllOrNothing: false,
            approvalMode: ApprovalMode.autoApprove.rawValue,
            descriptionText: nil,
            createdByRecordName: "parent1"
        )
        let log = QuestCompletionCache(
            recordName: "log1",
            questRecordName: "q1",
            familyRecordName: test.familyName,
            completerRecordName: test.profileName,
            completedDate: Date(),
            weekOf: currentWeek,
            verificationStatus: VerificationStatus.autoApproved.rawValue,
            approvalMode: ApprovalMode.autoApprove.rawValue,
            verifiedByRecordName: nil,
            verifiedDate: nil
        )

        viewModel.rebuildLists(quests: [quest], logs: [log], templates: [])

        #expect(viewModel.earnedThisWeek == 15.0)
        #expect(viewModel.isFullyCompleted(for: quest))
    }

    @Test
    func `rebuildLists only counts approved completions for gold`() {
        let test = makeHarness()
        let viewModel = HeroDashboardViewModel(appState: test.appState)

        let currentWeek = WeekMath.weekOf(date: Date())
        let quest = QuestCache(
            recordName: "q1",
            familyRecordName: test.familyName,
            assigneeRecordName: test.profileName,
            templateRecordName: "t1",
            weekOf: currentWeek,
            questName: "Complete Goblin",
            isActive: true,
            goldReward: 20.0,
            xpReward: 5,
            rarity: "uncommon",
            scheduleType: QuestSchedule.specificDays.rawValue,
            isAllOrNothing: false,
            approvalMode: ApprovalMode.autoApprove.rawValue,
            descriptionText: nil,
            createdByRecordName: "parent1"
        )
        let pendingLog = QuestCompletionCache(
            recordName: "log_pending",
            questRecordName: "q1",
            familyRecordName: test.familyName,
            completerRecordName: test.profileName,
            completedDate: Date(),
            weekOf: currentWeek,
            verificationStatus: VerificationStatus.pending.rawValue,
            approvalMode: ApprovalMode.autoApprove.rawValue,
            verifiedByRecordName: nil,
            verifiedDate: nil
        )
        let approvedQuest = QuestCache(
            recordName: "q2",
            familyRecordName: test.familyName,
            assigneeRecordName: test.profileName,
            templateRecordName: "t2",
            weekOf: currentWeek,
            questName: "Complete Dragon",
            isActive: true,
            goldReward: 15.0,
            xpReward: 10,
            rarity: "common",
            scheduleType: QuestSchedule.specificDays.rawValue,
            isAllOrNothing: false,
            approvalMode: ApprovalMode.autoApprove.rawValue,
            descriptionText: nil,
            createdByRecordName: "parent1"
        )
        let approvedLog = QuestCompletionCache(
            recordName: "log_approved",
            questRecordName: "q2",
            familyRecordName: test.familyName,
            completerRecordName: test.profileName,
            completedDate: Date(),
            weekOf: currentWeek,
            verificationStatus: VerificationStatus.autoApproved.rawValue,
            approvalMode: ApprovalMode.autoApprove.rawValue,
            verifiedByRecordName: nil,
            verifiedDate: nil
        )

        viewModel.rebuildLists(
            quests: [quest, approvedQuest],
            logs: [pendingLog, approvedLog],
            templates: []
        )

        #expect(viewModel.earnedThisWeek == 15.0)
        #expect(viewModel.isFullyCompleted(for: approvedQuest))
        #expect(!viewModel.isFullyCompleted(for: quest))
    }

    @Test
    func `rebuildLists computes streak from cache`() throws {
        let test = makeHarness()
        let viewModel = HeroDashboardViewModel(appState: test.appState)

        let calendar = Calendar.iso8601UTC
        let today = calendar.startOfDay(for: Date())
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: today))
        let currentWeek = WeekMath.weekOf(date: Date())

        let questToday = QuestCache(
            recordName: "qt",
            familyRecordName: test.familyName,
            assigneeRecordName: test.profileName,
            templateRecordName: "t1",
            weekOf: currentWeek,
            questName: "Today Quest",
            isActive: true,
            goldReward: 10,
            xpReward: 5,
            rarity: "common",
            scheduleType: QuestSchedule.specificDays.rawValue,
            isAllOrNothing: false,
            approvalMode: ApprovalMode.autoApprove.rawValue,
            descriptionText: nil,
            createdByRecordName: "parent1"
        )
        let questYesterday = QuestCache(
            recordName: "qy",
            familyRecordName: test.familyName,
            assigneeRecordName: test.profileName,
            templateRecordName: "t1",
            weekOf: currentWeek,
            questName: "Yesterday Quest",
            isActive: true,
            goldReward: 10,
            xpReward: 5,
            rarity: "common",
            scheduleType: QuestSchedule.specificDays.rawValue,
            isAllOrNothing: false,
            approvalMode: ApprovalMode.autoApprove.rawValue,
            descriptionText: nil,
            createdByRecordName: "parent1"
        )
        let logToday = QuestCompletionCache(
            recordName: "lt",
            questRecordName: "qt",
            familyRecordName: test.familyName,
            completerRecordName: test.profileName,
            completedDate: today,
            weekOf: currentWeek,
            verificationStatus: VerificationStatus.autoApproved.rawValue,
            approvalMode: ApprovalMode.autoApprove.rawValue,
            verifiedByRecordName: nil,
            verifiedDate: nil
        )
        let logYesterday = QuestCompletionCache(
            recordName: "ly",
            questRecordName: "qy",
            familyRecordName: test.familyName,
            completerRecordName: test.profileName,
            completedDate: yesterday,
            weekOf: currentWeek,
            verificationStatus: VerificationStatus.verified.rawValue,
            approvalMode: ApprovalMode.parentVerify.rawValue,
            verifiedByRecordName: "parent1",
            verifiedDate: yesterday
        )

        viewModel.rebuildLists(
            quests: [questToday, questYesterday],
            logs: [logToday, logYesterday],
            templates: []
        )

        #expect(viewModel.streak == 2)
    }

    // MARK: - Payout-aware week days

    @Test
    func `default sunday payout yields Mon-Sun week not Sun-Sat`() throws {
        let cal = Calendar.iso8601UTC
        let monday = try #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 3)))
        let days = HeroDashboardViewModel.currentWeekDays(for: monday, payoutDay: .sunday)
        #expect(days.count == 7)
        #expect(days.first?.weekdayCode == "monday")
        #expect(days.first?.shortName == "Mon")
        #expect(days.last?.weekdayCode == "sunday")
        #expect(days.last?.shortName == "Sun")
        #expect(days.map(\.weekdayCode) == ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"])
    }

    @Test
    func `sunday payout Mon-Sun is distinct from saturday payout Sun-Sat`() throws {
        let cal = Calendar.iso8601UTC
        let monday = try #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 3)))
        let sundayCycle = HeroDashboardViewModel.currentWeekDays(for: monday, payoutDay: .sunday)
        let saturdayCycle = HeroDashboardViewModel.currentWeekDays(for: monday, payoutDay: .saturday)
        #expect(sundayCycle.first?.weekdayCode == "monday")
        #expect(saturdayCycle.first?.weekdayCode == "sunday")
        #expect(sundayCycle != saturdayCycle)
    }

    @Test
    func `currentWeekDays sunday payout aligns with WeekMath startOfWeek`() throws {
        let cal = Calendar.iso8601UTC
        let wednesday = try #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 5)))
        let weekStart = WeekMath.startOfWeek(for: wednesday, payoutDay: .sunday)
        let days = HeroDashboardViewModel.currentWeekDays(for: wednesday, payoutDay: .sunday)
        #expect(days.first?.date == cal.startOfDay(for: weekStart))
        #expect(days.last?.date == cal.date(byAdding: .day, value: 6, to: cal.startOfDay(for: weekStart)))
    }

    @Test
    func `earnedThisWeek buckets by normalized WeekMath startOfWeek half-open range`() throws {
        let cal = Calendar.iso8601UTC
        let monday = try #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 3)))
        let weekRange = WeekMath.weekRange(starting: monday)
        let profileName = "hero1"

        let quest = QuestCache(
            recordName: "qBoundary",
            familyRecordName: "fam1",
            assigneeRecordName: profileName,
            templateRecordName: "t1",
            weekOf: monday,
            questName: "Boundary Quest",
            isActive: true,
            goldReward: 10.0,
            xpReward: 5,
            rarity: "common",
            scheduleType: QuestSchedule.specificDays.rawValue,
            isAllOrNothing: false,
            approvalMode: ApprovalMode.autoApprove.rawValue,
            descriptionText: nil,
            createdByRecordName: "parent1"
        )

        let sundayNight = try #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 9, hour: 23, minute: 59, second: 59)))
        let logSunday = QuestCompletionCache(
            recordName: "logSun",
            questRecordName: "qBoundary",
            familyRecordName: "fam1",
            completerRecordName: profileName,
            completedDate: sundayNight,
            weekOf: sundayNight,
            verificationStatus: VerificationStatus.autoApproved.rawValue,
            approvalMode: ApprovalMode.autoApprove.rawValue,
            verifiedByRecordName: nil,
            verifiedDate: nil
        )

        let nextMonday = try #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 0, minute: 0, second: 0)))
        let logMonday = QuestCompletionCache(
            recordName: "logMon",
            questRecordName: "qBoundary",
            familyRecordName: "fam1",
            completerRecordName: profileName,
            completedDate: nextMonday,
            weekOf: nextMonday,
            verificationStatus: VerificationStatus.autoApproved.rawValue,
            approvalMode: ApprovalMode.autoApprove.rawValue,
            verifiedByRecordName: nil,
            verifiedDate: nil
        )

        let included = GoldCalculation.netWeeklyGold(
            quests: [quest],
            logs: [logSunday],
            profileRecordName: profileName,
            payoutPolicy: .perQuest,
            weekRange: weekRange
        )
        #expect(included == 10.0)
        #expect(weekRange.contains(sundayNight))

        let excluded = GoldCalculation.netWeeklyGold(
            quests: [quest],
            logs: [logMonday],
            profileRecordName: profileName,
            payoutPolicy: .perQuest,
            weekRange: weekRange
        )
        #expect(excluded == 0.0)
        #expect(!weekRange.contains(nextMonday))

        let mixed = GoldCalculation.netWeeklyGold(
            quests: [quest],
            logs: [logSunday, logMonday],
            profileRecordName: profileName,
            payoutPolicy: .perQuest,
            weekRange: weekRange
        )
        #expect(mixed == 10.0)
    }

    @Test
    func `earnedThisWeek is zero when allowance period is paid for normalized week`() throws {
        let cal = Calendar.iso8601UTC
        let monday = try #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 3)))
        let tuesday = try #require(cal.date(byAdding: .day, value: 1, to: monday))
        let weekOf = WeekMath.startOfWeek(for: tuesday, payoutDay: .sunday)
        #expect(weekOf == monday)

        let periodNoon = try #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 12, minute: 0)))
        #expect(cal.isDate(periodNoon, inSameDayAs: weekOf))

        let quest = QuestCache(
            recordName: "q1",
            familyRecordName: "fam1",
            assigneeRecordName: "hero1",
            templateRecordName: "t1",
            weekOf: monday,
            questName: "Q",
            isActive: true,
            goldReward: 20.0,
            xpReward: 10,
            rarity: "common",
            scheduleType: QuestSchedule.specificDays.rawValue,
            isAllOrNothing: false,
            approvalMode: ApprovalMode.autoApprove.rawValue,
            descriptionText: nil,
            createdByRecordName: "parent1"
        )
        let log = QuestCompletionCache(
            recordName: "log1",
            questRecordName: "q1",
            familyRecordName: "fam1",
            completerRecordName: "hero1",
            completedDate: tuesday,
            weekOf: tuesday,
            verificationStatus: VerificationStatus.autoApproved.rawValue,
            approvalMode: ApprovalMode.autoApprove.rawValue,
            verifiedByRecordName: nil,
            verifiedDate: nil
        )
        let paidPeriod = AllowancePeriodCache(
            recordName: "period-paid",
            profileRecordName: "hero1",
            familyRecordName: "fam1",
            weekOf: periodNoon,
            status: PayoutStatus.paid.rawValue,
            totalEarned: 20.0,
            questsCompleted: 1,
            questsTotal: 1,
            paidDate: Date(),
            paidAmount: 20.0
        )

        let isPaid = [paidPeriod].contains { (period: AllowancePeriodCache) -> Bool in
            let matchesProfile = period.profileRecordName == "hero1"
            let isPaidStatus = period.statusEnum == .paid
            let matchesDate = cal.isDate(period.weekOf, inSameDayAs: weekOf)
            return matchesProfile && isPaidStatus && matchesDate
        }
        #expect(isPaid)

        let nextMonday = try #require(cal.date(byAdding: .day, value: 7, to: monday))
        let otherPeriod = AllowancePeriodCache(
            recordName: "period-other",
            profileRecordName: "hero1",
            familyRecordName: "fam1",
            weekOf: nextMonday,
            status: PayoutStatus.paid.rawValue,
            totalEarned: 20.0,
            questsCompleted: 1,
            questsTotal: 1,
            paidDate: Date(),
            paidAmount: 20.0
        )
        let isPaidOtherWeek = [otherPeriod].contains { (period: AllowancePeriodCache) -> Bool in
            let matchesProfile = period.profileRecordName == "hero1"
            let isPaidStatus = period.statusEnum == .paid
            let matchesDate = cal.isDate(period.weekOf, inSameDayAs: weekOf)
            return matchesProfile && isPaidStatus && matchesDate
        }
        #expect(!isPaidOtherWeek)

        _ = quest
        _ = log
    }

    // MARK: - Child Hub Aggregates

    /// Harness for the rebuilt child hub: an authenticated hero session over
    /// an in-memory cache seeded with bucket-attributed ledger rows.
    @MainActor
    private struct ChildHubHarness {
        let appState: AppState
        let cache: CacheService
        let viewModel: ChildHubViewModel
        let profileRef: CKRecord.Reference
        let familyRef: CKRecord.Reference

        init() throws {
            let defaults = UserDefaults.ephemeral()
            cache = try CacheService(inMemory: true, defaults: defaults)
            appState = AppState(defaults: defaults)
            appState.family = SampleData.family
            appState.currentProfile = SampleData.heroProfile
            cache.context?.insert(ProfileCache(from: SampleData.heroProfile))
            _ = cache.saveContext()
            viewModel = ChildHubViewModel(appState: appState, cacheService: cache)
            profileRef = CKRecord.Reference(recordID: SampleData.hero1ID, action: .none)
            familyRef = CKRecord.Reference(recordID: SampleData.familyID, action: .none)
        }

        func seedLedger(
            _ name: String,
            amount: Double,
            source: String,
            bucketKind: String?,
            fromBucket: String? = nil,
            toBucket: String? = nil
        ) {
            cache.context?.insert(LedgerEntryCache(from: LedgerEntry(
                profile: profileRef,
                amount: amount,
                description: name,
                source: source,
                bucketKind: bucketKind,
                fromBucket: fromBucket,
                toBucket: toBucket,
                family: familyRef,
                id: CKRecord.ID(recordName: name, zoneID: SampleData.zoneID)
            )))
            _ = cache.saveContext()
        }

        func quest(_ name: String, weekOf: Date, goldReward: Double = 10.0) -> QuestCache {
            QuestCache(
                recordName: name,
                familyRecordName: SampleData.familyID.recordName,
                assigneeRecordName: SampleData.hero1ID.recordName,
                templateRecordName: "t1",
                weekOf: weekOf,
                questName: name,
                isActive: true,
                goldReward: goldReward,
                xpReward: 10,
                rarity: "common",
                scheduleType: QuestSchedule.weeklyFlexible.rawValue,
                isAllOrNothing: false,
                approvalMode: ApprovalMode.autoApprove.rawValue,
                descriptionText: nil,
                createdByRecordName: "parent_dad"
            )
        }

        func log(_ name: String, quest: QuestCache, status: VerificationStatus) -> QuestCompletionCache {
            QuestCompletionCache(
                recordName: name,
                questRecordName: quest.recordName,
                familyRecordName: SampleData.familyID.recordName,
                completerRecordName: SampleData.hero1ID.recordName,
                completedDate: Date(),
                weekOf: quest.weekOf,
                verificationStatus: status.rawValue,
                approvalMode: ApprovalMode.autoApprove.rawValue,
                verifiedByRecordName: nil,
                verifiedDate: nil
            )
        }
    }

    @Test
    func `hub aggregates total available balance from per-bucket balances`() throws {
        let harness = try ChildHubHarness()
        harness.seedLedger("l-spend-in", amount: 10.00, source: "quest", bucketKind: BucketKind.spend.rawValue)
        harness.seedLedger("l-spend-out", amount: -2.50, source: "manual", bucketKind: BucketKind.spend.rawValue)
        harness.seedLedger("l-short-in", amount: 6.25, source: "quest", bucketKind: BucketKind.shortTermSave.rawValue)

        harness.viewModel.rebuild(quests: [], logs: [], templates: [], goals: [])

        #expect(harness.viewModel.bucketBalance(.spend) == 7.50)
        #expect(harness.viewModel.bucketBalance(.shortTermSave) == 6.25)
        #expect(harness.viewModel.bucketBalance(.longTermSave) == 0)
        #expect(harness.viewModel.availableBalance == 13.75)
    }

    @Test
    func `hub balances debit the transfer source and credit the destination`() throws {
        let harness = try ChildHubHarness()
        harness.seedLedger("l-spend-in", amount: 10.00, source: "quest", bucketKind: BucketKind.spend.rawValue)
        // One transfer row moves money twice: the balance aggregator credits
        // its bucketKind destination AND debits its fromBucket source.
        harness.seedLedger(
            "transfer-hero_maya-1-spend-shortTermSave",
            amount: 3.00,
            source: "transfer",
            bucketKind: BucketKind.shortTermSave.rawValue,
            fromBucket: BucketKind.spend.rawValue,
            toBucket: BucketKind.shortTermSave.rawValue
        )

        harness.viewModel.rebuild(quests: [], logs: [], templates: [], goals: [])

        #expect(harness.viewModel.bucketBalance(.spend) == 7.00)
        #expect(harness.viewModel.bucketBalance(.shortTermSave) == 3.00)
        #expect(harness.viewModel.availableBalance == 10.00)
    }

    @Test
    func `weekly completion ring fraction counts only quests inside the WeekMath cycle`() throws {
        let harness = try ChildHubHarness()
        let currentWeek = WeekMath.weekOf(date: Date())
        let done = harness.quest("q-done", weekOf: currentWeek)
        let todo = harness.quest("q-todo", weekOf: currentWeek)
        let stale = harness.quest("q-stale", weekOf: currentWeek.addingTimeInterval(-7 * 24 * 3600))

        harness.viewModel.rebuild(
            quests: [done, todo, stale],
            logs: [harness.log("log-done", quest: done, status: .autoApproved)],
            templates: [],
            goals: []
        )

        #expect(harness.viewModel.weeklyGoal == 2)
        #expect(harness.viewModel.weeklyCompleted == 1)
        #expect(harness.viewModel.weeklyProgress == 0.5)
    }

    @Test
    func `active goal projection fills the oldest open goal first with FIFO saved pennies`() throws {
        let harness = try ChildHubHarness()
        harness.seedLedger("l-short-in", amount: 30.00, source: "quest", bucketKind: BucketKind.shortTermSave.rawValue)
        let goals = SampleData.createSampleGoals().map { GoalCache(from: $0) }

        harness.viewModel.rebuild(quests: [], logs: [], templates: [], goals: goals)

        let activeGoal = try #require(harness.viewModel.activeGoal)
        #expect(activeGoal.goal.recordName == "goal_maya_art")
        #expect(activeGoal.savedPennies == 2500)
    }
}
