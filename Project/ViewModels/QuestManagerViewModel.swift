import CloudKit
import Foundation
import Observation

enum QuestEditLockedError: LocalizedError {
    case lockedFields

    var errorDescription: String? {
        switch self {
        case .lockedFields:
            "This quest has log entries. Gold, XP, schedule, and assignee are locked."
        }
    }
}

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

    private var syncSubscriptionID: UUID?
    private var syncTask: Task<Void, Never>?

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
        let created = try await questService.createTemplate(
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

        // Optimistically add to templates immediately
        templates.append(created)
        templates.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if let fetched = try? await questService.fetchTemplates(family: family) {
            templates = fetched
        }
    }

    func updateTemplate(_ template: QuestTemplate) async throws {
        let saved = try await questService.updateTemplate(template)
        if let idx = templates.firstIndex(where: { $0.id == saved.id }) {
            templates[idx] = saved
        }
        if let family = appState.family,
           let fetched = try? await questService.fetchTemplates(family: family)
        {
            templates = fetched
        }
    }

    func deactivateTemplate(_ template: QuestTemplate) async throws {
        let saved = try await questService.deactivateTemplate(template)
        if let idx = templates.firstIndex(where: { $0.id == saved.id }) {
            templates[idx] = saved
        }
        if let family = appState.family,
           let fetched = try? await questService.fetchTemplates(family: family)
        {
            templates = fetched
        }
    }

    func reactivateTemplate(_ template: QuestTemplate) async throws {
        var active = template
        active.isActive = true
        let saved = try await questService.updateTemplate(active)
        if let idx = templates.firstIndex(where: { $0.id == saved.id }) {
            templates[idx] = saved
        }
        if let family = appState.family,
           let fetched = try? await questService.fetchTemplates(family: family)
        {
            templates = fetched
        }
    }

    func assignQuest(template: QuestTemplate,
                     assignee: Profile,
                     goldOverride: Double?,
                     xpOverride: Int?,
                     approvalOverride: ApprovalMode?,
                     nameOverride: String? = nil,
                     weekOf: Date) async throws
    {
        guard let parent = appState.currentProfile,
              let family = appState.family
        else {
            throw QuestServiceError.missingSession
        }
        let created = try await questService.assignQuest(
            template: template,
            assignee: assignee,
            goldOverride: goldOverride,
            xpOverride: xpOverride,
            approvalOverride: approvalOverride,
            nameOverride: nameOverride,
            weekOf: weekOf,
            createdBy: parent,
            family: family
        )

        // Optimistically add assignment
        activeAssignments.removeAll { $0.id == created.id }
        activeAssignments.append(created)

        if let fetched = try? await questService.fetchQuestsForFamilyWeek(family: family, weekOf: weekOf) {
            // Reconcile: merge fetched with optimistic list, dedupe by recordID, prefer newer
            var merged = fetched
            for optimistic in activeAssignments where !fetched.contains(where: { $0.id == optimistic.id }) {
                merged.append(optimistic)
            }
            activeAssignments = merged
        }
    }

    // Quest assignment form collects many fields; consolidating into a struct would be an API change outside lint scope.
    // swiftlint:disable:next function_parameter_count
    func assignQuickQuest(name: String,
                          description: String,
                          assignee: Profile,
                          goldReward: Double,
                          xpReward: Int,
                          scheduleType: QuestSchedule,
                          specificDays: [String],
                          approvalMode: ApprovalMode,
                          weekOf: Date) async throws
    {
        guard let parent = appState.currentProfile,
              let family = appState.family
        else {
            throw QuestServiceError.missingSession
        }
        let created = try await questService.assignQuickQuest(
            name: name,
            description: description,
            assignee: assignee,
            goldReward: goldReward,
            xpReward: xpReward,
            scheduleType: scheduleType,
            specificDays: specificDays,
            approvalMode: approvalMode,
            weekOf: weekOf,
            createdBy: parent,
            family: family
        )

        // Optimistically add assignment
        activeAssignments.removeAll { $0.id == created.id }
        activeAssignments.append(created)

        if let fetched = try? await questService.fetchQuestsForFamilyWeek(family: family, weekOf: weekOf) {
            // Reconcile: merge fetched with optimistic list, dedupe by recordID, prefer newer
            var merged = fetched
            for optimistic in activeAssignments where !fetched.contains(where: { $0.id == optimistic.id }) {
                merged.append(optimistic)
            }
            activeAssignments = merged
        }
    }

    // swiftlint:disable:next function_parameter_count
    func updateQuest(_ quest: Quest,
                     name: String?,
                     descriptionText: String?,
                     goldReward: Double,
                     xpReward: Int,
                     scheduleType: QuestSchedule,
                     isAllOrNothing: Bool,
                     approvalMode: ApprovalMode,
                     assignee: Profile,
                     allowLockedFieldsOverride: Bool) async throws
    {
        guard let family = appState.family else {
            throw QuestServiceError.missingSession
        }

        // If quest has logs, only name and descriptionText may change
        if !allowLockedFieldsOverride {
            let logs = try await questService.fetchQuestLogs(forQuest: quest)
            if !logs.isEmpty {
                // Verify only name/description are changing
                let fieldsChanged = quest.goldReward != goldReward
                    || quest.xpReward != xpReward
                    || quest.scheduleType != scheduleType
                    || quest.assignee.recordID != assignee.id
                if fieldsChanged {
                    throw QuestEditLockedError.lockedFields
                }
            }
        }

        var updated = quest
        updated.name = name
        updated.descriptionText = descriptionText
        updated.goldReward = goldReward
        updated.xpReward = xpReward
        updated.scheduleType = scheduleType
        updated.isAllOrNothing = isAllOrNothing
        updated.approvalMode = approvalMode
        updated.assignee = CKRecord.Reference(recordID: assignee.id, action: .none)

        _ = try await questService.updateQuest(updated)

        // Update in place
        if let idx = activeAssignments.firstIndex(where: { $0.id == quest.id }) {
            activeAssignments[idx] = updated
        }

        // Re-fetch to stay consistent
        if let fetched = try? await questService.fetchQuestsForFamilyWeek(family: family, weekOf: quest.weekOf) {
            var merged = fetched
            for optimistic in activeAssignments where !fetched.contains(where: { $0.id == optimistic.id }) {
                merged.append(optimistic)
            }
            activeAssignments = merged
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

    func subscribeToSyncEvents(_ coordinator: AppSyncCoordinator) {
        guard syncSubscriptionID == nil else { return }
        let (stream, id) = coordinator.subscribe()
        syncSubscriptionID = id
        syncTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .recordChanged, .shareAccepted, .zoneReset:
                    await self.load()
                    await self.loadHeroes()
                }
            }
        }
    }

    func unsubscribeFromSyncEvents(_ coordinator: AppSyncCoordinator) {
        syncTask?.cancel()
        syncTask = nil
        if let id = syncSubscriptionID {
            coordinator.unsubscribe(id: id)
            syncSubscriptionID = nil
        }
    }

    func loadHeroes() async {
        guard let family = appState.family else {
            heroes = []
            return
        }

        heroes = await (try? familyService.fetchHeroes(for: family)) ?? []
    }
}
