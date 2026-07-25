//
//  HeroDashboardViewModel.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
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
    private(set) var todaysQuests: [Quest] = []
    private(set) var weeklyFlexibleQuests: [Quest] = []
    private(set) var completedQuests: [Quest] = []
    private(set) var upcomingQuests: [Quest] = []
    private(set) var missedQuests: [Quest] = []
    private(set) var weekQuests: [Quest] = []

    private(set) var streak: Int = 0
    private(set) var earnedThisWeek: Double = 0
    private(set) var availableTemplatesCount: Int = 0
    private(set) var logsByQuestID: [CKRecord.ID: QuestCompletion] = [:]

    private(set) var weekDays: [DayInfo] = []
    var selectedDayCode: String?

    var loadError: String?
    private(set) var isLoading: Bool = false

    private let questService: QuestService
    private let appState: AppState

    private var templatesByID: [String: QuestTemplate] = [:]

    init(questService: QuestService, appState: AppState) {
        self.questService = questService
        self.appState = appState
        weekDays = HeroDashboardViewModel.currentWeekDays()
    }

    func load() async {
        guard let profile = appState.currentProfile, let family = appState.family else {
            todaysQuests = []
            weeklyFlexibleQuests = []
            completedQuests = []
            upcomingQuests = []
            missedQuests = []
            weekQuests = []
            streak = 0
            earnedThisWeek = 0
            availableTemplatesCount = 0
            return
        }

        isLoading = true
        defer { isLoading = false }

        weekDays = HeroDashboardViewModel.currentWeekDays()

        do {
            async let questsTask = questService.fetchActiveQuests(profile: profile, weekOf: Date())
            async let logsTask = questService.fetchQuestLogs(for: profile)
            async let streakTask = questService.fetchStreak(for: profile)
            async let earnedTask = questService.earnedThisWeek(profile: profile, weekOf: Date())
            async let templatesTask = questService.fetchTemplates(family: family)

            let quests = await (try? questsTask) ?? []
            let logs = await (try? logsTask) ?? []
            let streak = await (try? streakTask) ?? 0
            let earned = await (try? earnedTask) ?? 0
            let templates = await (try? templatesTask) ?? []

            let todayCode = HeroDashboardViewModel.todayWeekdayCode()
            templatesByID = Dictionary(
                uniqueKeysWithValues: templates.map { ($0.id.recordName, $0) }
            )
            logsByQuestID = Dictionary(
                logs.map { ($0.quest.recordID, $0) },
                uniquingKeysWith: { first, _ in first }
            )

            let completedQuestIDs = Set(
                logs.filter { $0.verificationStatus != .rejected }
                    .map(\.quest.recordID)
            )

            var completed: [Quest] = []
            var todayList: [Quest] = []
            var flexibleList: [Quest] = []
            var upcoming: [Quest] = []
            var missed: [Quest] = []

            for quest in quests {
                if completedQuestIDs.contains(quest.id) {
                    completed.append(quest)
                    continue
                }

                let specDays: [String] = {
                    if let template = templatesByID[quest.template.recordID.recordName] {
                        return template.specificDays
                    }
                    return []
                }()

                switch quest.scheduleType {
                case .weeklyFlexible:
                    flexibleList.append(quest)

                case .specificDays:
                    if specDays.contains(todayCode) {
                        todayList.append(quest)
                    }

                    // Check if days are strictly in the past
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

                    if isPastOnly {
                        missed.append(quest)
                    } else if hasFutureDay, !specDays.contains(todayCode) {
                        upcoming.append(quest)
                    }
                }
            }

            weekQuests = quests
            completedQuests = completed
            todaysQuests = todayList
            weeklyFlexibleQuests = flexibleList
            upcomingQuests = upcoming
            missedQuests = missed

            self.streak = streak
            earnedThisWeek = earned
            availableTemplatesCount = templates.filter(\.isActive).count
            loadError = nil
        } catch {
            loadError = "Could not load quests: \(error.localizedDescription)"
        }
    }

    func rebuildLists(quests: [Quest], logs: [QuestCompletion]) {
        let todayCode = HeroDashboardViewModel.todayWeekdayCode()

        logsByQuestID = Dictionary(
            logs.map { ($0.quest.recordID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let completedQuestIDs = Set(
            logs.filter { $0.verificationStatus != .rejected }
                .map(\.quest.recordID)
        )

        var completed: [Quest] = []
        var todayList: [Quest] = []
        var flexibleList: [Quest] = []
        var upcoming: [Quest] = []
        var missed: [Quest] = []

        for quest in quests {
            if completedQuestIDs.contains(quest.id) {
                completed.append(quest)
                continue
            }

            let specDays: [String] = {
                if let template = templatesByID[quest.template.recordID.recordName] {
                    return template.specificDays
                }
                return []
            }()

            switch quest.scheduleType {
            case .weeklyFlexible:
                flexibleList.append(quest)

            case .specificDays:
                if specDays.contains(todayCode) {
                    todayList.append(quest)
                }

                // Check if days are strictly in the past
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

                if isPastOnly {
                    missed.append(quest)
                } else if hasFutureDay, !specDays.contains(todayCode) {
                    upcoming.append(quest)
                }
            }
        }

        weekQuests = quests
        completedQuests = completed
        todaysQuests = todayList
        weeklyFlexibleQuests = flexibleList
        upcomingQuests = upcoming
        missedQuests = missed
    }

    func questsForSelectedDay() -> [Quest] {
        guard let selectedDayCode else { return weekQuests }
        return weekQuests.filter { quest in
            switch quest.scheduleType {
            case .weeklyFlexible:
                return false
            case .specificDays:
                if let template = templatesByID[quest.template.recordID.recordName] {
                    return template.specificDays.contains(selectedDayCode)
                }
                return true
            }
        }
    }

    func hasQuests(on day: DayInfo) -> Bool {
        weekQuests.contains { quest in
            switch quest.scheduleType {
            case .weeklyFlexible:
                return false
            case .specificDays:
                if let template = templatesByID[quest.template.recordID.recordName] {
                    return template.specificDays.contains(day.weekdayCode)
                }
                return false
            }
        }
    }

    func isDayCompleted(day: DayInfo) -> Bool {
        let dayQuests = weekQuests.filter { quest in
            if quest.scheduleType == .specificDays,
               let template = templatesByID[quest.template.recordID.recordName]
            {
                return template.specificDays.contains(day.weekdayCode)
            }
            return false
        }
        guard !dayQuests.isEmpty else { return false }
        return dayQuests.allSatisfy { quest in
            completedQuests.contains(where: { $0.id == quest.id })
        }
    }

    func log(for quest: Quest) -> QuestCompletion? {
        logsByQuestID[quest.id]
    }

    static func todayWeekdayCode() -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current

        let weekdayIndex = cal.component(.weekday, from: Date()) - 1
        let codes = AppConstants.weekdayCodes
        let safe = max(0, min(codes.count - 1, weekdayIndex))
        return codes[safe]
    }

    static func currentWeekDays(for date: Date = Date()) -> [DayInfo] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current

        let weekday = cal.component(.weekday, from: date) // 1 (Sun) to 7 (Sat)
        let daysToSunday = 1 - weekday
        guard let sundayDate = cal.date(byAdding: .day, value: daysToSunday, to: cal.startOfDay(for: date)) else {
            return []
        }

        let codes = AppConstants.weekdayCodes
        let shortNames = AppConstants.weekdayShort

        let todayStart = cal.startOfDay(for: date)

        return (0 ..< 7).compactMap { offset in
            guard let dayDate = cal.date(byAdding: .day, value: offset, to: sundayDate) else { return nil }
            let dayStart = cal.startOfDay(for: dayDate)
            let isToday = cal.isDate(dayStart, inSameDayAs: todayStart)
            let isPast = dayStart < todayStart
            let isFuture = dayStart > todayStart
            let dayNum = cal.component(.day, from: dayDate)

            return DayInfo(
                id: codes[offset],
                date: dayDate,
                weekdayCode: codes[offset],
                shortName: shortNames[offset],
                dayNumber: dayNum,
                isToday: isToday,
                isPast: isPast,
                isFuture: isFuture
            )
        }
    }
}

private extension Quest {
    func isScheduledFor(weekdayCode _: String) -> Bool {
        scheduleType == .weeklyFlexible || true
    }
}
