//
//  HeroDashboardViewModel.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation
import Observation

struct DayInfo: Identifiable, Hashable {
    let id: String
    let date: Date
    let weekdayCode: String
    let shortName: String
    let dayNumber: Int
    let isToday: Bool
    let isPast: Bool
    let isFuture: Bool
}

@MainActor
@Observable
final class HeroDashboardViewModel {
    // MARK: - Properties

    private(set) var todaysQuests: [QuestCache] = []
    private(set) var overdueQuests: [QuestCache] = []
    private(set) var weeklyFlexibleQuests: [QuestCache] = []
    private(set) var upcomingQuests: [QuestCache] = []
    private(set) var weekQuests: [QuestCache] = []

    private(set) var streak: Int = 0
    private(set) var earnedThisWeek: Double = 0
    private(set) var availableTemplatesCount: Int = 0
    private(set) var logsByQuestRecordName: [String: QuestCompletionCache] = [:]
    private(set) var allLogsByQuestRecordName: [String: [QuestCompletionCache]] = [:]
    private(set) var completedQuestCount: Int = 0

    private(set) var weekDays: [DayInfo] = []
    var selectedDayCode: String?

    private let appState: AppState

    private var templatesByID: [String: QuestTemplateCache] = [:]

    init(appState: AppState) {
        self.appState = appState
        // Default mirrors the effective payout fallback (.sunday) used in
        // rebuildLists so the initial weekDays do not shift by one day before
        // the first cache-driven rebuild.
        weekDays = HeroDashboardViewModel.currentWeekDays()
    }

    // MARK: - List Building

    /// Synchronous rebuild from SwiftData `@Query` rows using pure cache math.
    func rebuildLists(quests: [QuestCache], logs: [QuestCompletionCache], templates: [QuestTemplateCache] = [], allowancePeriods: [AllowancePeriodCache] = []) {
        guard let profileName = appState.currentProfile?.id.recordName,
              appState.family != nil
        else { return }

        let payoutDay = appState.resolvedPayoutDay
        weekDays = HeroDashboardViewModel.currentWeekDays(payoutDay: payoutDay)
        let todayCode = HeroDashboardViewModel.todayWeekdayCode()

        if !templates.isEmpty {
            templatesByID = Dictionary(
                uniqueKeysWithValues: templates.map { ($0.recordName, $0) }
            )
        }

        var multiLogs: [String: [QuestCompletionCache]] = [:]
        for log in logs {
            multiLogs[log.questRecordName, default: []].append(log)
        }
        allLogsByQuestRecordName = multiLogs

        logsByQuestRecordName = Dictionary(
            logs.map { ($0.questRecordName, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var todayList: [QuestCache] = []
        var overdueList: [QuestCache] = []
        var flexibleList: [QuestCache] = []
        var upcoming: [QuestCache] = []

        for quest in quests {
            let specDays: [String] = {
                if let template = templatesByID[quest.templateRecordName] {
                    return template.specificDays ?? []
                }
                return []
            }()

            switch quest.scheduleTypeEnum {
            case .weeklyFlexible:
                flexibleList.append(quest)

            case .specificDays:
                let isPastOnly = !specDays.isEmpty && specDays.allSatisfy { code in
                    if let day = weekDays.first(where: { $0.weekdayCode == code }) {
                        return day.isPast
                    }
                    return false
                }

                let hasFutureDay = specDays.contains { code in
                    if let day = weekDays.first(where: { $0.weekdayCode == code }) {
                        return day.isFuture
                    }
                    return false
                }

                let isToday = specDays.contains(todayCode)
                let isCompleted = isFullyCompleted(for: quest)

                if isPastOnly, !isCompleted {
                    overdueList.append(quest)
                } else if isToday || (isPastOnly && isCompleted) {
                    todayList.append(quest)
                } else if hasFutureDay {
                    upcoming.append(quest)
                } else {
                    todayList.append(quest)
                }

            default:
                break
            }
        }

        weekQuests = quests
        overdueQuests = overdueList
        todaysQuests = todayList
        weeklyFlexibleQuests = flexibleList
        upcomingQuests = upcoming
        availableTemplatesCount = templatesByID.values.filter(\.isActive).count

        let heroLogs = logs.filter { $0.completerRecordName == profileName }
        streak = StreakCalculator.computeStreak(from: heroLogs)
        let profileRecordName = appState.currentProfile?.id.recordName ?? ""
        let payoutPolicy = appState.currentProfile?.payoutPolicy ?? appState.family?.payoutPolicy
        earnedThisWeek = Self.earnedThisWeek(
            logs: heroLogs,
            quests: quests,
            allowancePeriods: allowancePeriods,
            profileRecordName: profileRecordName,
            payoutPolicy: payoutPolicy,
            payoutDay: payoutDay
        )

        completedQuestCount = quests.reduce(0) { count, quest in
            count + (isFullyCompleted(for: quest) ? 1 : 0)
        }
    }

    // MARK: - Helpers

    func logs(for quest: QuestCache) -> [QuestCompletionCache] {
        allLogsByQuestRecordName[quest.recordName] ?? []
    }

    func approvedCount(for quest: QuestCache) -> Int {
        logs(for: quest).filter {
            $0.verificationStatusEnum == .verified || $0.verificationStatusEnum == .autoApproved
        }.count
    }

    func isFullyCompleted(for quest: QuestCache) -> Bool {
        GoldCalculation.isFullyCompleted(quest: quest, approvedCount: approvedCount(for: quest))
    }

    // MARK: - Weekly Earnings

    nonisolated static func earnedThisWeek(
        logs: [QuestCompletionCache],
        quests: [QuestCache],
        allowancePeriods: [AllowancePeriodCache] = [],
        profileRecordName: String,
        payoutPolicy: PayoutPolicy?,
        payoutDay: PayoutDay = .sunday
    ) -> Double {
        let weekOf = WeekMath.startOfWeek(for: Date(), payoutDay: payoutDay)
        // Compare normalized week starts rather than isDate(inSameDayAs:) to
        // avoid daylight-boundary mismatches when stored weekOf values straddle
        // a DST transition in a non-UTC calendar.
        let isPaid = allowancePeriods.contains {
            $0.profileRecordName == profileRecordName &&
                $0.statusEnum == .paid &&
                WeekMath.startOfWeek(for: $0.weekOf, payoutDay: payoutDay) == weekOf
        }
        if isPaid {
            return 0.0
        }
        let weekRange = WeekMath.weekRange(starting: weekOf)
        return GoldCalculation.netWeeklyGold(
            quests: quests,
            logs: logs,
            profileRecordName: profileRecordName,
            payoutPolicy: payoutPolicy,
            weekRange: weekRange
        )
    }

    func questsForSelectedDay() -> [QuestCache] {
        guard let selectedDayCode else { return weekQuests }
        return weekQuests.filter { quest in
            switch quest.scheduleTypeEnum {
            case .weeklyFlexible:
                return false
            case .specificDays:
                if let template = templatesByID[quest.templateRecordName] {
                    return (template.specificDays ?? []).contains(selectedDayCode)
                }
                return true
            default:
                return false
            }
        }
    }

    func hasQuests(on day: DayInfo) -> Bool {
        weekQuests.contains { quest in
            switch quest.scheduleTypeEnum {
            case .weeklyFlexible:
                return false
            case .specificDays:
                if let template = templatesByID[quest.templateRecordName] {
                    return template.specificDays?.contains(day.weekdayCode) == true
                }
                return false
            default:
                return false
            }
        }
    }

    func isDayCompleted(day: DayInfo) -> Bool {
        let dayQuests = weekQuests.filter { quest in
            if quest.scheduleTypeEnum == .specificDays,
               let template = templatesByID[quest.templateRecordName]
            {
                return template.specificDays?.contains(day.weekdayCode) == true
            }
            return false
        }
        guard !dayQuests.isEmpty else { return false }
        return dayQuests.allSatisfy { quest in
            let approvedLogs = logs(for: quest).filter {
                $0.verificationStatusEnum == .verified || $0.verificationStatusEnum == .autoApproved
            }
            return GoldCalculation.isFullyCompleted(quest: quest, approvedCount: approvedLogs.count)
        }
    }

    func log(for quest: QuestCache) -> QuestCompletionCache? {
        logsByQuestRecordName[quest.recordName]
    }

    // MARK: - Date Helpers

    static func todayWeekdayCode(calendar: Calendar = .iso8601UTC) -> String {
        WeekMath.todayWeekdayCode(calendar: calendar)
    }

    // MARK: - Week Strip

    static func currentWeekDays(for date: Date = Date(), payoutDay: PayoutDay = .sunday, calendar: Calendar = .iso8601UTC) -> [DayInfo] {
        let startDate = WeekMath.startOfWeek(for: date, payoutDay: payoutDay)

        let todayStart = calendar.startOfDay(for: date)

        return (0 ..< 7).compactMap { offset in
            guard let dayDate = calendar.date(byAdding: .day, value: offset, to: startDate) else { return nil }
            let dayStart = calendar.startOfDay(for: dayDate)
            let isToday = WeekMath.dayBucket(for: dayStart) == WeekMath.dayBucket(for: todayStart)
            let isPast = WeekMath.dayBucket(for: dayStart) < WeekMath.dayBucket(for: todayStart)
            let isFuture = WeekMath.dayBucket(for: dayStart) > WeekMath.dayBucket(for: todayStart)
            let dayNum = calendar.component(.day, from: dayDate)
            let weekdayCode = WeekMath.weekdayCode(for: dayDate, calendar: calendar)

            return DayInfo(
                id: weekdayCode,
                date: dayDate,
                weekdayCode: weekdayCode,
                shortName: WeekMath.shortName(for: weekdayCode),
                dayNumber: dayNum,
                isToday: isToday,
                isPast: isPast,
                isFuture: isFuture
            )
        }
    }
}
