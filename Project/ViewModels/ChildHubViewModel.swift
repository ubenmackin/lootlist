//
//  ChildHubViewModel.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import Foundation
import Observation

/// One row in the hub's Today's Chores list. Pending-review rows render amber
/// (the chore is done from the child's perspective, waiting on a parent);
/// everything else renders as an upcoming to-do with an amount pill.
struct ChoreRowItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let amount: Double
    let isPendingReview: Bool
    let questRecordName: String
    let completionRecordName: String?

    init(
        id: String,
        title: String,
        subtitle: String?,
        amount: Double,
        isPendingReview: Bool,
        questRecordName: String? = nil,
        completionRecordName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.amount = amount
        self.isPendingReview = isPendingReview
        self.questRecordName = questRecordName ?? id
        self.completionRecordName = completionRecordName
    }
}

/// The FIFO head goal driving the Active Goal card, with its cache-derived
/// saved total in pennies.
struct ActiveGoalSummary: Identifiable {
    let goal: GoalCache
    let savedPennies: Int64

    var id: String {
        goal.recordName
    }
}

@MainActor
@Observable
final class ChildHubViewModel {
    private(set) var bucketBalances: [BucketKind: Double] = [:]
    private(set) var choreRows: [ChoreRowItem] = []
    private(set) var weeklyCompleted: Int = 0
    private(set) var weeklyGoal: Int = 0
    private(set) var streak: Int = 0
    private(set) var activeGoal: ActiveGoalSummary?

    private let appState: AppState
    private let bucketService: BucketService

    init(appState: AppState, cacheService: CacheService?) {
        self.appState = appState
        self.bucketService = BucketService(cacheService: cacheService as (any CacheServicing)?)
    }

    // MARK: - Derived Figures

    var availableBalance: Double {
        BucketKind.allCases.reduce(0) { $0 + (bucketBalances[$1] ?? 0) }
    }

    func bucketBalance(_ kind: BucketKind) -> Double {
        bucketBalances[kind] ?? 0
    }

    var pendingReviewCount: Int {
        choreRows.lazy.filter(\.isPendingReview).count
    }

    var toDoCount: Int {
        choreRows.count - pendingReviewCount
    }

    var weeklyProgress: Double {
        weeklyGoal > 0 ? Double(weeklyCompleted) / Double(weeklyGoal) : 0
    }

    var streakHint: String {
        streak > 0
            ? "🔥 \(streak)-day streak! Keep it up to earn streak bonus!"
            : "Complete chores to build a streak bonus!"
    }

    var todayCode: String {
        WeekMath.todayWeekdayCode()
    }

    // MARK: - Rebuild

    /// Cache-first synchronous rebuild from SwiftData `@Query` rows. Never
    /// throws and never touches CloudKit, so the hub hydrates instantly offline.
    func rebuild(
        quests: [QuestCache],
        logs: [QuestCompletionCache],
        templates: [QuestTemplateCache],
        goals: [GoalCache]
    ) {
        guard let profile = appState.currentProfile,
              let familyName = appState.family?.id.recordName
        else {
            bucketBalances = [:]
            choreRows = []
            weeklyCompleted = 0
            weeklyGoal = 0
            streak = 0
            activeGoal = nil
            return
        }
        let profileName = profile.id.recordName

        // Fail-closed when the cache row for the profile is missing (pruned or not yet reconciled).
        let cache = bucketService.cacheService
        if cache.fetchProfile(recordName: profileName, family: familyName) == nil {
            bucketBalances = [:]
            choreRows = []
            weeklyCompleted = 0
            weeklyGoal = 0
            streak = 0
            activeGoal = nil
            return
        }

        bucketBalances = bucketService.bucketBalances(profileRecordName: profileName, familyRecordName: familyName)
        let ledgerEntries = bucketService.cacheService
            .fetchLedgerEntries(profileRecordName: profileName, family: familyName)

        let myQuests = quests.filter { $0.assigneeRecordName == profileName && $0.isActive }
        let myLogs = logs.filter { $0.completerRecordName == profileName }
        // WHY: questsByID includes inactive quests so pending reviews stay visible after template deactivation; to-do list is separately filtered via myQuests.isActive.
        let questsByID = Dictionary(
            quests.map { ($0.recordName, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let templatesByID = Dictionary(
            templates.filter(\.isActive).map { ($0.recordName, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // WHY: Week boundaries come exclusively from WeekMath so the hub's progress
        // window matches payout cycles everywhere else in the app.
        let payoutDay = appState.resolvedPayoutDay
        let weekRange = WeekMath.weekRange(starting: WeekMath.startOfWeek(for: Date(), payoutDay: payoutDay))
        let weekQuests = myQuests.filter { weekRange.contains($0.weekOf) }

        choreRows = buildChoreRows(
            weekQuests: weekQuests,
            myLogs: myLogs,
            questsByID: questsByID,
            templatesByID: templatesByID
        )

        weeklyGoal = weekQuests.count
        weeklyCompleted = weekQuests.filter { quest in
            let approved = myLogs.filter { $0.questRecordName == quest.recordName && $0.isApproved }.count
            return GoldCalculation.isFullyCompleted(quest: quest, approvedCount: approved)
        }.count

        streak = StreakCalculator.computeStreak(from: myLogs)

        // Goals fill FIFO within their bucket: the oldest incomplete
        // non-archived goal is the one the child is actively working on.
        let openGoals = goals
            .filter { $0.profileRecordName == profileName && !$0.isArchived && $0.completedAt == nil }
            .sorted { $0.createdAt < $1.createdAt }
        if let topGoal = openGoals.first {
            let allocations = GoalProgressCalculator.allocations(goals: goals, ledgerEntries: ledgerEntries)
            activeGoal = ActiveGoalSummary(goal: topGoal, savedPennies: allocations[topGoal.recordName] ?? 0)
        } else {
            activeGoal = nil
        }

        // Publish snapshot to WidgetDataBridge for Lock Screen widgets.
        let todayBucket = WeekMath.dayBucket(for: Date())
        let todayLogs = myLogs.filter { WeekMath.dayBucket(for: $0.completedDate) == todayBucket && ($0.isApproved || $0.verificationStatusEnum == .pending) }
        let savingsStreak = StreakCalculator.computeSavingsStreak(from: ledgerEntries, profileRecordName: profileName, payoutDay: payoutDay)
        let nextChore = choreRows.first(where: { !$0.isPendingReview })?.title

        let snapshot = WidgetSnapshot(
            todayCompletedQuests: todayLogs.count,
            todayTotalQuests: max(todayLogs.count, weekQuests.count),
            dailyQuestStreak: streak,
            weeklySavingsStreak: savingsStreak,
            activeGoalName: activeGoal?.goal.name,
            activeGoalTargetPennies: activeGoal?.goal.targetAmountPennies,
            activeGoalSavedPennies: activeGoal?.savedPennies,
            activeGoalEmoji: activeGoal?.goal.emojiIcon,
            nextQuestTitle: nextChore,
            lastUpdated: Date()
        )
        WidgetDataBridge.saveSnapshot(snapshot)
    }

    // MARK: - Chore Rows

    private func buildChoreRows(
        weekQuests: [QuestCache],
        myLogs: [QuestCompletionCache],
        questsByID: [String: QuestCache],
        templatesByID: [String: QuestTemplateCache]
    ) -> [ChoreRowItem] {
        var rows: [ChoreRowItem] = []

        // Pending review leads the list; a pending log still occupies a
        // completion slot, so an in-review quest drops off the to-do list
        // until the parent responds.
        let pendingLogs = myLogs
            .filter { $0.verificationStatusEnum == .pending }
            .sorted { $0.completedDate > $1.completedDate }
        for log in pendingLogs {
            guard let quest = questsByID[log.questRecordName] else { continue }
            // WHY: Keep deactivated quests visible for in-flight reviews; surface stale reward without hiding the row.
            let subtitle = quest.isActive ? "Sent to Parent for Review" : "Sent to Parent for Review — quest deactivated"
            rows.append(ChoreRowItem(
                id: log.recordName,
                title: quest.questName,
                subtitle: subtitle,
                amount: quest.goldReward,
                isPendingReview: true,
                questRecordName: quest.recordName,
                completionRecordName: log.recordName
            ))
        }

        // Weekday code comes from todayCode so due-text and the week strip
        // anchor on the same UTC weekday source.
        let code = todayCode
        let logsByQuest = Dictionary(grouping: myLogs, by: \.questRecordName)

        let open = weekQuests.filter { quest in
            let questLogs = logsByQuest[quest.recordName] ?? []
            let approved = questLogs.filter(\.isApproved).count
            let occupied = questLogs.filter { $0.verificationStatusEnum?.countsTowardCompletion == true }.count
            return !GoldCalculation.isFullyCompleted(quest: quest, approvedCount: approved)
                && occupied < quest.targetCount
        }

        // Today's scheduled chores lead, then the rest of the week.
        let sorted = open.sorted { lhs, rhs in
            let lhsToday = Self.isScheduledToday(lhs, templatesByID: templatesByID, todayCode: code)
            let rhsToday = Self.isScheduledToday(rhs, templatesByID: templatesByID, todayCode: code)
            if lhsToday != rhsToday {
                return lhsToday
            }
            return lhs.weekOf < rhs.weekOf
        }

        for quest in sorted {
            rows.append(ChoreRowItem(
                id: quest.recordName,
                title: quest.questName,
                subtitle: Self.dueText(for: quest, templatesByID: templatesByID, todayCode: code),
                amount: quest.goldReward,
                isPendingReview: false,
                questRecordName: quest.recordName,
                completionRecordName: nil
            ))
        }
        return rows
    }

    private static func isScheduledToday(
        _ quest: QuestCache,
        templatesByID: [String: QuestTemplateCache],
        todayCode: String
    ) -> Bool {
        guard quest.scheduleTypeEnum == .specificDays,
              let days = templatesByID[quest.templateRecordName]?.specificDays
        else { return false }
        return days.contains(todayCode)
    }

    private static func dueText(
        for quest: QuestCache,
        templatesByID: [String: QuestTemplateCache],
        todayCode: String
    ) -> String {
        guard quest.scheduleTypeEnum == .specificDays else { return "This Week" }
        let days = templatesByID[quest.templateRecordName]?.specificDays ?? []
        if days.contains(todayCode) {
            return "Due Today"
        }
        // WHY: Next weekday lookup via WeekMath so due-text ordering stays payout-anchored and UTC-consistent.
        if let next = WeekMath.nextWeekdayCode(after: todayCode, candidates: days) {
            return "Due \(WeekMath.shortName(for: next))"
        }
        return "This Week"
    }
}
