//
//  HeroDashboardMyChoresTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/31/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct HeroDashboardMyChoresTests {
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

    private func myChoresCompleted(weekQuests: [QuestCache], logs: [QuestCompletionCache]) -> [(QuestCache, QuestCompletionCache)] {
        var result: [(QuestCache, QuestCompletionCache)] = []
        for quest in weekQuests {
            let approved = logs.filter { $0.questRecordName == quest.recordName && $0.isApproved }
            if GoldCalculation.isFullyCompleted(quest: quest, approvedCount: approved.count),
               let latest = approved.sorted(by: { $0.completedDate > $1.completedDate }).first
            {
                result.append((quest, latest))
            }
        }
        return result
    }

    @Test
    func `myChores completed excludes previous week quest`() {
        let payoutDay: PayoutDay = .sunday
        let currentWeek = WeekMath.weekOf(date: Date())
        let previousWeek = WeekMath.weekStart(byAddingWeeks: -1, to: currentWeek)
        let weekRange = WeekMath.range(for: Date(), payoutDay: payoutDay).range
        func quest(_ name: String, weekOf: Date) -> QuestCache {
            QuestCache(
                recordName: name,
                familyRecordName: SampleData.familyID.recordName,
                assigneeRecordName: SampleData.hero1ID.recordName,
                templateRecordName: "t1",
                weekOf: weekOf,
                questName: name,
                isActive: true,
                goldReward: 10.0,
                xpReward: 10,
                rarity: "common",
                scheduleType: QuestSchedule.weeklyFlexible.rawValue,
                isAllOrNothing: false,
                approvalMode: ApprovalMode.autoApprove.rawValue,
                descriptionText: nil,
                createdByRecordName: "parent_dad"
            )
        }
        let current = quest("q-current", weekOf: currentWeek)
        let previous = quest("q-previous", weekOf: previousWeek)
        let weekQuests = [current, previous].filter { WeekMath.isQuestInCurrentWeek($0.weekOf, range: weekRange) }
        #expect(weekQuests.count == 1)
        #expect(weekQuests.first?.recordName == "q-current")
        let logs = [
            QuestCompletionCache(
                recordName: "log-current", questRecordName: current.recordName, familyRecordName: SampleData.familyID.recordName,
                completerRecordName: SampleData.hero1ID.recordName,
                completedDate: Date(), weekOf: currentWeek, verificationStatus: VerificationStatus.autoApproved.rawValue, approvalMode: ApprovalMode.autoApprove.rawValue,
                verifiedByRecordName: nil, verifiedDate: nil
            ),
            QuestCompletionCache(
                recordName: "log-previous", questRecordName: previous.recordName, familyRecordName: SampleData.familyID.recordName,
                completerRecordName: SampleData.hero1ID.recordName, completedDate: Date(), weekOf: previousWeek, verificationStatus: VerificationStatus.autoApproved.rawValue,
                approvalMode: ApprovalMode.autoApprove.rawValue, verifiedByRecordName: nil, verifiedDate: nil
            )
        ]
        let completed = myChoresCompleted(weekQuests: weekQuests, logs: logs)
        #expect(completed.count == 1)
        #expect(completed.first?.0.recordName == "q-current")
    }

    @Test
    func `myChores upcoming excludes completed pending and overdue`() {
        let payoutDay: PayoutDay = .sunday
        let currentWeek = WeekMath.weekOf(date: Date())
        let midWeekDate = Calendar.iso8601UTC.date(byAdding: .day, value: 3, to: currentWeek) ?? Date()
        let weekRange = WeekMath.range(for: midWeekDate, payoutDay: payoutDay).range
        let weekDays = HeroDashboardViewModel.currentWeekDays(for: midWeekDate, payoutDay: payoutDay)
        // Pick a past day and a future day for overdue vs upcoming distinction.
        guard let pastCode = weekDays.first(where: \.isPast)?.weekdayCode,
              let futureCode = weekDays.first(where: \.isFuture)?.weekdayCode
        else {
            Issue.record("Expected both past and future days mid-week")
            return
        }
        let templatePast = QuestTemplateCache(
            recordName: "t-past",
            familyRecordName: SampleData.familyID.recordName,
            name: "Past Template",
            isActive: true,
            goldReward: 5,
            xpReward: 10,
            rarity: "common",
            specificDays: [pastCode],
            templateDescription: "",
            scheduleType: QuestSchedule.specificDays.rawValue,
            isAllOrNothing: false,
            approvalMode: ApprovalMode.autoApprove.rawValue,
            createdByRecordName: "parent_dad"
        )
        let templateFuture = QuestTemplateCache(
            recordName: "t-future",
            familyRecordName: SampleData.familyID.recordName,
            name: "Future Template",
            isActive: true,
            goldReward: 5,
            xpReward: 10,
            rarity: "common",
            specificDays: [futureCode],
            templateDescription: "",
            scheduleType: QuestSchedule.specificDays.rawValue,
            isAllOrNothing: false,
            approvalMode: ApprovalMode.autoApprove.rawValue,
            createdByRecordName: "parent_dad"
        )
        let templatesByID: [String: QuestTemplateCache] = ["t-past": templatePast, "t-future": templateFuture]
        func quest(_ name: String, template: String) -> QuestCache {
            QuestCache(
                recordName: name,
                familyRecordName: SampleData.familyID.recordName,
                assigneeRecordName: SampleData.hero1ID.recordName,
                templateRecordName: template,
                weekOf: currentWeek,
                questName: name,
                isActive: true,
                goldReward: 5,
                xpReward: 10,
                rarity: "common",
                scheduleType: QuestSchedule.specificDays.rawValue,
                isAllOrNothing: false,
                approvalMode: ApprovalMode.autoApprove.rawValue,
                descriptionText: nil,
                createdByRecordName: "parent_dad"
            )
        }
        let completedQ = quest("q-completed", template: "t-future")
        let pendingQ = quest("q-pending", template: "t-future")
        let overdueQ = quest("q-overdue", template: "t-past")
        let upcomingQ = quest("q-upcoming", template: "t-future")
        let weekQuests = [completedQ, pendingQ, overdueQ, upcomingQ].filter { WeekMath.isQuestInCurrentWeek($0.weekOf, range: weekRange) }
        let logs: [QuestCompletionCache] = [
            QuestCompletionCache(
                recordName: "log-completed",
                questRecordName: completedQ.recordName,
                familyRecordName: SampleData.familyID.recordName,
                completerRecordName: SampleData.hero1ID.recordName,
                completedDate: Date(),
                weekOf: currentWeek,
                verificationStatus: VerificationStatus.autoApproved.rawValue,
                approvalMode: ApprovalMode.autoApprove.rawValue,
                verifiedByRecordName: nil,
                verifiedDate: nil
            ),
            QuestCompletionCache(
                recordName: "log-pending",
                questRecordName: pendingQ.recordName,
                familyRecordName: SampleData.familyID.recordName,
                completerRecordName: SampleData.hero1ID.recordName,
                completedDate: Date(),
                weekOf: currentWeek,
                verificationStatus: VerificationStatus.pending.rawValue,
                approvalMode: ApprovalMode.parentVerify.rawValue,
                verifiedByRecordName: nil,
                verifiedDate: nil
            )
        ]
        let completed = myChoresCompleted(weekQuests: weekQuests, logs: logs)
        let completedNames = Set(completed.map(\.0.recordName))
        let pendingNames = Set(logs.filter { $0.verificationStatusEnum == .pending }.map(\.questRecordName))
        let overdue: [QuestCache] = weekQuests.filter { quest in
            if pendingNames.contains(quest.recordName) {
                return false
            }
            if completedNames.contains(quest.recordName) {
                return false
            }
            guard quest.scheduleTypeEnum == .specificDays else { return false }
            let specDays = templatesByID[quest.templateRecordName]?.specificDays ?? []
            guard !specDays.isEmpty else { return false }
            return specDays.allSatisfy { code in
                guard let day = weekDays.first(where: { $0.weekdayCode == code }) else { return false }
                return day.isPast
            }
        }
        let overdueNames = Set(overdue.map(\.recordName))
        let upcoming = weekQuests.filter { quest in
            !pendingNames.contains(quest.recordName) && !completedNames.contains(quest.recordName) && !overdueNames.contains(quest.recordName)
        }
        #expect(upcoming.count == 1)
        #expect(upcoming.first?.recordName == "q-upcoming")
    }

    @Test
    func `myChores overdueThisWeek detects specificDays past only`() {
        let payoutDay: PayoutDay = .sunday
        let currentWeek = WeekMath.weekOf(date: Date())
        let midWeekDate = Calendar.iso8601UTC.date(byAdding: .day, value: 3, to: currentWeek) ?? Date()
        let weekRange = WeekMath.range(for: midWeekDate, payoutDay: payoutDay).range
        let weekDays = HeroDashboardViewModel.currentWeekDays(for: midWeekDate, payoutDay: payoutDay)
        let pastCodes = weekDays.filter(\.isPast).map(\.weekdayCode)
        let futureCodes = weekDays.filter(\.isFuture).map(\.weekdayCode)
        guard let pastOnlyCode = pastCodes.first,
              let futureOnlyCode = futureCodes.first
        else {
            Issue.record("Expected both past and future days mid-week")
            return
        }
        let mixedCodes = Array([pastOnlyCode, futureOnlyCode])
        func template(_ name: String, days: [String]) -> QuestTemplateCache {
            QuestTemplateCache(
                recordName: name,
                familyRecordName: SampleData.familyID.recordName,
                name: name,
                isActive: true,
                goldReward: 5,
                xpReward: 10,
                rarity: "common",
                specificDays: days,
                templateDescription: "",
                scheduleType: QuestSchedule.specificDays.rawValue,
                isAllOrNothing: false,
                approvalMode: ApprovalMode.autoApprove.rawValue,
                createdByRecordName: "parent_dad"
            )
        }
        let tPast = template("t-past", days: [pastOnlyCode])
        let tFuture = template("t-future", days: [futureOnlyCode])
        let tMixed = template("t-mixed", days: mixedCodes)
        let tWeekly = template("t-weekly", days: [])
        let templatesByID: [String: QuestTemplateCache] = ["t-past": tPast, "t-future": tFuture, "t-mixed": tMixed, "t-weekly": tWeekly]
        func quest(_ name: String, template: String) -> QuestCache {
            let sched = template == "t-weekly" ? QuestSchedule.weeklyFlexible.rawValue : QuestSchedule.specificDays.rawValue
            return QuestCache(
                recordName: name,
                familyRecordName: SampleData.familyID.recordName,
                assigneeRecordName: SampleData.hero1ID.recordName,
                templateRecordName: template,
                weekOf: currentWeek,
                questName: name,
                isActive: true,
                goldReward: 5,
                xpReward: 10,
                rarity: "common",
                scheduleType: sched,
                isAllOrNothing: false,
                approvalMode: ApprovalMode.autoApprove.rawValue,
                descriptionText: nil,
                createdByRecordName: "parent_dad"
            )
        }
        let qPast = quest("q-past", template: "t-past")
        let qFuture = quest("q-future", template: "t-future")
        let qMixed = quest("q-mixed", template: "t-mixed")
        let qWeekly = quest("q-weekly", template: "t-weekly")
        let weekQuests = [qPast, qFuture, qMixed, qWeekly].filter { WeekMath.isQuestInCurrentWeek($0.weekOf, range: weekRange) }
        let completedNames: Set<String> = []
        let pendingNames: Set<String> = []
        let overdue = weekQuests.filter { quest in
            if pendingNames.contains(quest.recordName) {
                return false
            }
            if completedNames.contains(quest.recordName) {
                return false
            }
            guard quest.scheduleTypeEnum == .specificDays else { return false }
            let specDays = templatesByID[quest.templateRecordName]?.specificDays ?? []
            guard !specDays.isEmpty else { return false }
            return specDays.allSatisfy { code in
                guard let day = weekDays.first(where: { $0.weekdayCode == code }) else { return false }
                return day.isPast
            }
        }
        #expect(overdue.map(\QuestCache.recordName).contains("q-past"))
        #expect(!overdue.map(\QuestCache.recordName).contains("q-future"))
        #expect(!overdue.map(\QuestCache.recordName).contains("q-mixed"))
        #expect(!overdue.map(\QuestCache.recordName).contains("q-weekly"))
    }

    @Test
    func `myChores missedLastWeek disclosure shows previousWeek only`() {
        let payoutDay: PayoutDay = .sunday
        let currentWeek = WeekMath.weekOf(date: Date())
        let previousWeek = WeekMath.weekStart(byAddingWeeks: -1, to: currentWeek)
        let twoWeeksAgo = WeekMath.weekStart(byAddingWeeks: -2, to: currentWeek)
        let weekRange = WeekMath.range(for: Date(), payoutDay: payoutDay).range
        let previousRange = WeekMath.weekRange(starting: previousWeek)
        func quest(_ name: String, weekOf: Date) -> QuestCache {
            QuestCache(
                recordName: name,
                familyRecordName: SampleData.familyID.recordName,
                assigneeRecordName: SampleData.hero1ID.recordName,
                templateRecordName: "t1",
                weekOf: weekOf,
                questName: name,
                isActive: true,
                goldReward: 5,
                xpReward: 10,
                rarity: "common",
                scheduleType: QuestSchedule.weeklyFlexible.rawValue,
                isAllOrNothing: false,
                approvalMode: ApprovalMode.autoApprove.rawValue,
                descriptionText: nil,
                createdByRecordName: "parent_dad"
            )
        }
        let currentQ = quest("q-current", weekOf: currentWeek)
        let previousIncomplete = quest("q-prev-incomplete", weekOf: previousWeek)
        let previousCompleted = quest("q-prev-completed", weekOf: previousWeek)
        let twoAgo = quest("q-two-ago", weekOf: twoWeeksAgo)
        let weekQuests = [currentQ, previousIncomplete, previousCompleted, twoAgo].filter { WeekMath.isQuestInCurrentWeek($0.weekOf, range: weekRange) }
        #expect(weekQuests.count == 1)
        let allQuests = [currentQ, previousIncomplete, previousCompleted, twoAgo]
        let missedCandidates = allQuests.filter { WeekMath.isQuestInCurrentWeek($0.weekOf, range: previousRange) }
        #expect(missedCandidates.count == 2)
        let logs = [
            QuestCompletionCache(
                recordName: "log-prev-completed",
                questRecordName: previousCompleted.recordName,
                familyRecordName: SampleData.familyID.recordName,
                completerRecordName: SampleData.hero1ID.recordName,
                completedDate: Date(),
                weekOf: previousWeek,
                verificationStatus: VerificationStatus.autoApproved.rawValue,
                approvalMode: ApprovalMode.autoApprove.rawValue,
                verifiedByRecordName: nil,
                verifiedDate: nil
            )
        ]
        let missedLastWeek = missedCandidates.filter { quest in
            let approved = logs.filter { $0.questRecordName == quest.recordName && $0.isApproved }.count
            return !GoldCalculation.isFullyCompleted(quest: quest, approvedCount: approved)
        }
        #expect(missedLastWeek.count == 1)
        #expect(missedLastWeek.first?.recordName == "q-prev-incomplete")
    }

    @Test
    func `myChores isAllOrNothing does not affect weekly ring`() throws {
        let harness = try ChildHubHarness()
        let currentWeek = WeekMath.weekOf(date: Date())
        let aonQuest = QuestCache(
            recordName: "q-aon-mychores",
            familyRecordName: SampleData.familyID.recordName,
            assigneeRecordName: SampleData.hero1ID.recordName,
            templateRecordName: "t1",
            weekOf: currentWeek,
            questName: "AON",
            isActive: true,
            goldReward: 10.0,
            xpReward: 10,
            rarity: "common",
            scheduleType: QuestSchedule.weeklyFlexible.rawValue,
            targetCount: 3,
            isAllOrNothing: true,
            approvalMode: ApprovalMode.autoApprove.rawValue,
            descriptionText: nil,
            createdByRecordName: "parent_dad"
        )
        let normalQuest = QuestCache(
            recordName: "q-normal",
            familyRecordName: SampleData.familyID.recordName,
            assigneeRecordName: SampleData.hero1ID.recordName,
            templateRecordName: "t2",
            weekOf: currentWeek,
            questName: "Normal",
            isActive: true,
            goldReward: 10.0,
            xpReward: 10,
            rarity: "common",
            scheduleType: QuestSchedule.weeklyFlexible.rawValue,
            targetCount: 3,
            isAllOrNothing: false,
            approvalMode: ApprovalMode.autoApprove.rawValue,
            descriptionText: nil,
            createdByRecordName: "parent_dad"
        )
        let logs = [
            QuestCompletionCache(
                recordName: "log-aon",
                questRecordName: aonQuest.recordName,
                familyRecordName: SampleData.familyID.recordName,
                completerRecordName: SampleData.hero1ID.recordName,
                completedDate: Date(),
                weekOf: currentWeek,
                verificationStatus: VerificationStatus.autoApproved.rawValue,
                approvalMode: ApprovalMode.autoApprove.rawValue,
                verifiedByRecordName: nil,
                verifiedDate: nil
            )
        ]
        harness.viewModel.rebuild(quests: [aonQuest, normalQuest], logs: logs, templates: [], goals: [])
        #expect(harness.viewModel.weeklyGoal == 6)
        #expect(harness.viewModel.weeklyCompleted == 1)
    }
}
