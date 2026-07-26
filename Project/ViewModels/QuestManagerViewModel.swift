//
//  QuestManagerViewModel.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

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
    private(set) var templates: [QuestTemplateCache] = []

    private(set) var activeAssignments: [QuestCache] = []

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

        let familyName = family.id.recordName
        if let cache = appState.cacheService {
            let templates = cache.fetchQuestTemplates(family: familyName)
            let quests = cache.fetchQuests(family: familyName).filter(\.isActive)
            rebuildLists(templates: templates, assignments: quests)
        }
    }

    func rebuildLists(templates: [QuestTemplateCache], assignments: [QuestCache]) {
        self.templates = templates
        activeAssignments = assignments
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
    }

    func updateTemplate(_ template: QuestTemplate) async throws {
        _ = try await questService.updateTemplate(template)
    }

    func deactivateTemplate(_ template: QuestTemplate) async throws {
        _ = try await questService.deactivateTemplate(template)
    }

    func reactivateTemplate(_ template: QuestTemplate) async throws {
        var active = template
        active.isActive = true
        _ = try await questService.updateTemplate(active)
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
        _ = try await questService.assignQuest(
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
        _ = try await questService.assignQuickQuest(
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
        guard appState.family != nil else {
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
    }

    func unassignQuest(_ quest: Quest) async throws {
        try await questService.unassignQuest(quest)
        activeAssignments.removeAll { $0.recordName == quest.id.recordName }
    }

    func fetchPendingQuestLogs() async throws -> [QuestCompletion] {
        guard let family = appState.family else {
            throw QuestServiceError.missingSession
        }
        let all = try await questService.fetchQuestsForFamilyWeek(
            family: family, weekOf: QuestService.mondayOfWeek(for: Date())
        )

        // Single batch fetch — replaces per-quest N+1 queries.
        let allCompletions = await (try? questService.fetchQuestCompletionsForFamily(family: family)) ?? []

        var completionsByQuest: [String: [QuestCompletion]] = [:]
        for completion in allCompletions {
            completionsByQuest[completion.quest.recordID.recordName, default: []].append(completion)
        }

        // Preserve the original "all pending logs" semantic: the per-quest path
        // returned every log for the quest (sorted by completedDate desc) and the
        // caller-wide filter kept only pending ones. Taking just `.first` here
        // would silently drop an earlier pending log when a newer log for the same
        // quest is verified/rejected/autoApproved, so iterate all logs and keep
        // every pending entry. `completionsByQuest` preserves the descending
        // completedDate order from `fetchQuestCompletionsForFamily`, so appended
        // pending logs remain newest-first within each quest.
        var pending: [QuestCompletion] = []
        for quest in all where quest.approvalMode == .parentVerify {
            let logs = completionsByQuest[quest.id.recordName] ?? []
            for log in logs where log.verificationStatus == .pending {
                pending.append(log)
            }
        }
        return pending
    }

    private(set) var heroes: [ProfileCache] = []

    func rebuildHeroes(profiles: [ProfileCache]) {
        heroes = profiles.filter { $0.role == UserRole.hero.rawValue }
    }

    func subscribeToSyncEvents(_ coordinator: AppSyncCoordinator) {
        guard syncSubscriptionID == nil else { return }
        let (stream, id) = coordinator.subscribe()
        syncSubscriptionID = id
        syncTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .recordChanged, .shareAccepted, .zoneReset:
                    await load()
                    await loadHeroes()
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

        if let cache = appState.cacheService {
            heroes = cache.fetchProfiles(family: family.id.recordName).filter { $0.role == UserRole.hero.rawValue }
        }
    }
}
