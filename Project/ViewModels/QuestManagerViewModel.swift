import CloudKit
import Foundation
import Observation

@MainActor
@Observable
final class QuestManagerViewModel {
    private(set) var templates: [QuestTemplate] = []

    private(set) var activeAssignments: [Quest] = []

    private(set) var isLoading: Bool = false

    var loadError: String?

    private let questService: QuestService
    private let familyService: FamilyService
    private let appState: AppState

    init(questService: QuestService, familyService: FamilyService, appState: AppState) {
        self.questService = questService
        self.familyService = familyService
        self.appState = appState
    }

    func load() async {
        guard let family = appState.family else {
            templates = []
            activeAssignments = []
            return
        }

        isLoading = true
        defer { isLoading = false }

        async let templatesTask: [QuestTemplate]? = try? questService.fetchTemplates(family: family)
        async let assignmentsTask: [Quest]? = try? questService.fetchQuestsForFamilyWeek(
            family: family, weekOf: Date()
        )

        templates = await templatesTask ?? []
        activeAssignments = await assignmentsTask ?? []

        if loadError != nil {
            loadError = nil
        }
    }

    func createTemplate(name: String,
                        description: String,
                        defaultGold: Double,
                        xpReward: Int,
                        schedule: QuestSchedule,
                        specificDays: [String],
                        isAllOrNothing: Bool = false,
                        approvalMode: ApprovalMode) async throws
    {
        guard let parent = appState.currentProfile,
              let family = appState.family
        else {
            throw QuestServiceError.missingSession
        }
        _ = try await questService.createTemplate(
            name: name,
            description: description,
            defaultGold: defaultGold,
            xpReward: xpReward,
            schedule: schedule,
            specificDays: specificDays,
            isAllOrNothing: isAllOrNothing,
            approvalMode: approvalMode,
            createdBy: parent,
            family: family
        )

        if let family = appState.family {
            templates = await (try? questService.fetchTemplates(family: family)) ?? templates
        }
    }

    func updateTemplate(_ template: QuestTemplate) async throws {
        _ = try await questService.updateTemplate(template)
        if let family = appState.family {
            templates = await (try? questService.fetchTemplates(family: family)) ?? templates
        }
    }

    func deactivateTemplate(_ template: QuestTemplate) async throws {
        _ = try await questService.deactivateTemplate(template)
        if let family = appState.family {
            templates = await (try? questService.fetchTemplates(family: family)) ?? templates
        }
    }

    func reactivateTemplate(_ template: QuestTemplate) async throws {
        var active = template
        active.isActive = true
        _ = try await questService.updateTemplate(active)
        if let family = appState.family {
            templates = await (try? questService.fetchTemplates(family: family)) ?? templates
        }
    }

    func assignQuest(template: QuestTemplate,
                     assignee: Profile,
                     goldOverride: Double?,
                     xpOverride: Int?,
                     approvalOverride: ApprovalMode?,
                     weekOf: Date) async throws
    {
        guard let parent = appState.currentProfile,
              let family = appState.family
        else {
            throw QuestServiceError.missingSession
        }
        _ = try await questService.assignQuest(
            template: template,
            assignee: assignee,
            goldOverride: goldOverride,
            xpOverride: xpOverride,
            approvalOverride: approvalOverride,
            weekOf: weekOf,
            createdBy: parent,
            family: family
        )
        if let family = appState.family {
            activeAssignments = await (try? questService.fetchQuestsForFamilyWeek(
                family: family, weekOf: weekOf
            )) ?? activeAssignments
        }
    }

    func unassignQuest(_ quest: Quest) async throws {
        try await questService.unassignQuest(quest)

        activeAssignments.removeAll { $0.id == quest.id }
    }

    func fetchPendingQuestLogs() async throws -> [QuestCompletion] {
        guard let family = appState.family else {
            throw QuestServiceError.missingSession
        }
        let all = try await questService.fetchQuestsForFamilyWeek(family: family, weekOf: Date())
        var pending: [QuestCompletion] = []
        for quest in all where quest.approvalMode == .parentVerify {
            let logs = try await questService.fetchQuestLogs(forQuest: quest)
            if let mostRecent = logs.first, mostRecent.verificationStatus == .pending {
                pending.append(mostRecent)
            }
        }
        return pending
    }

    private(set) var heroes: [Profile] = []

    func loadHeroes() async {
        guard let family = appState.family else {
            heroes = []
            return
        }

        heroes = await (try? familyService.fetchHeroes(for: family)) ?? []
    }

}
