import CloudKit
import Foundation
import Observation

@MainActor
@Observable
final class HeroDashboardViewModel {
    private(set) var todaysQuests: [Quest] = []

    private(set) var streak: Int = 0

    private(set) var earnedThisWeek: Double = 0

    private(set) var availableTemplatesCount: Int = 0

    var loadError: String?

    private(set) var isLoading: Bool = false

    private let questService: QuestService
    private let appState: AppState

    init(questService: QuestService, appState: AppState) {
        self.questService = questService
        self.appState = appState
    }

    func load() async {
        guard let profile = appState.currentProfile, let family = appState.family else {
            todaysQuests = []
            streak = 0
            earnedThisWeek = 0
            availableTemplatesCount = 0
            return
        }

        isLoading = true
        defer { isLoading = false }

        async let questsTask: [Quest]? = try? questService.fetchActiveQuests(
            profile: profile, weekOf: Date()
        )
        async let streakTask: Int? = try? questService.fetchStreak(for: profile)
        async let earnedTask: Double? = try? questService.earnedThisWeek(
            profile: profile, weekOf: Date()
        )
        async let templatesTask: [QuestTemplate]? = try? questService.fetchTemplates(family: family)

        let quests = await questsTask ?? []
        let streak = await streakTask ?? 0
        let earned = await earnedTask ?? 0
        let templates = await templatesTask ?? []

        let todayCode = HeroDashboardViewModel.todayWeekdayCode()
        let templatesByID: [String: QuestTemplate] = Dictionary(
            uniqueKeysWithValues: templates.map { ($0.id.recordName, $0) }
        )

        todaysQuests = quests.filter { quest in
            switch quest.scheduleType {
            case .weeklyFlexible:
                return true
            case .specificDays:
                guard let template = templatesByID[quest.template.recordID.recordName] else {
                    return true
                }
                return template.specificDays.contains(todayCode)
            }
        }
        self.streak = streak
        earnedThisWeek = earned
        availableTemplatesCount = templates.filter(\.isActive).count

        if loadError != nil {
            loadError = nil
        }
    }

    static func todayWeekdayCode() -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current

        let weekdayIndex = cal.component(.weekday, from: Date()) - 1
        let codes = ["sunday", "monday", "tuesday", "wednesday",
                     "thursday", "friday", "saturday"]
        let safe = max(0, min(codes.count - 1, weekdayIndex))
        return codes[safe]
    }
}
