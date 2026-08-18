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
        let weekDays = HeroDashboardViewModel.currentWeekDays()
        #expect(weekDays.count == 7)
        #expect(weekDays.first?.weekdayCode == "sunday")
        #expect(weekDays.first?.shortName == "Sun")
        #expect(weekDays.last?.weekdayCode == "saturday")
        #expect(weekDays.last?.shortName == "Sat")
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
        // `appState.family != nil` guard (lines 51-53) doesn't early-return.
        // Route the family's `CKRecord.ID` through the same `zoneID`/`"fam1"`
        // recordName the harness already uses for the profile's `family`
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
        // A second quest with an APPROVED completion must be counted — proves
        // the harness exercises the real approved-status filter path (the
        // the harness `appState.family` fix, because `rebuildLists` early
        // returned at its `appState.family != nil` guard). Seeding an approved
        // completion that IS counted rules out any future early-return
        // regression masking the pending-exclusion check.
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

        // `earnedThisWeek` derives gold via the STRICT approved-status join
        // (`autoApproved` || `verified`) inside `Self.earnedThisWeek`, so the
        // pending `q1` completion (20.0 gold) is excluded and only the
        // autoApproved `q2` completion (15.0 gold) is counted.
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
}
