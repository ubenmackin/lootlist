import Foundation
import CloudKit
import Observation

@MainActor
@Observable
final class QuestManagerViewModel {

    private(set) var templates: [QuestTemplate] = []

    private(set) var activeAssignments: [Quest] = []

    private(set) var isLoading: Bool = false

    var loadError: String?

    private let questService: QuestService
    private let appState: AppState

    init(questService: QuestService, appState: AppState) {
        self.questService = questService
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

        self.templates = await templatesTask ?? []
        self.activeAssignments = await assignmentsTask ?? []

        if loadError != nil { loadError = nil }
    }

    func createTemplate(name: String,
                        description: String,
                        defaultGold: Double,
                        xpReward: Int,
                        schedule: QuestSchedule,
                        specificDays: [String],
                        approvalMode: ApprovalMode) async throws {
        guard let parent = appState.currentProfile,
              let family = appState.family else {
            throw QuestServiceError.missingSession
        }
        _ = try await questService.createTemplate(
            name: name,
            description: description,
            defaultGold: defaultGold,
            xpReward: xpReward,
            schedule: schedule,
            specificDays: specificDays,
            approvalMode: approvalMode,
            createdBy: parent,
            family: family
        )

        if let family = appState.family {
            self.templates = (try? await questService.fetchTemplates(family: family)) ?? templates
        }
    }

    func updateTemplate(_ template: QuestTemplate) async throws {
        _ = try await questService.updateTemplate(template)
        if let family = appState.family {
            self.templates = (try? await questService.fetchTemplates(family: family)) ?? templates
        }
    }

    func deactivateTemplate(_ template: QuestTemplate) async throws {
        _ = try await questService.deactivateTemplate(template)
        if let family = appState.family {
            self.templates = (try? await questService.fetchTemplates(family: family)) ?? templates
        }
    }

    func reactivateTemplate(_ template: QuestTemplate) async throws {
        var active = template
        active.isActive = true
        _ = try await questService.updateTemplate(active)
        if let family = appState.family {
            self.templates = (try? await questService.fetchTemplates(family: family)) ?? templates
        }
    }

    func assignQuest(template: QuestTemplate,
                     assignee: Profile,
                     goldOverride: Double?,
                     xpOverride: Int?,
                     approvalOverride: ApprovalMode?,
                     weekOf: Date) async throws {
        guard let parent = appState.currentProfile,
              let family = appState.family else {
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
            self.activeAssignments = (try? await questService.fetchQuestsForFamilyWeek(
                family: family, weekOf: weekOf
            )) ?? activeAssignments
        }
    }

    func unassignQuest(_ quest: Quest) async throws {
        try await questService.unassignQuest(quest)

        self.activeAssignments.removeAll { $0.id == quest.id }
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

        let cloudKit = questService.cloudKitReference
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let predicate = NSPredicate(format: "family == %@", familyRef)
        let all = (try? await cloudKit.query(Profile.self, predicate: predicate)) ?? []
        self.heroes = all
            .filter { $0.role == .hero && $0.isActive }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var cloudKitReference: CloudKitService {

        questService.cloudKitReference
    }
}
