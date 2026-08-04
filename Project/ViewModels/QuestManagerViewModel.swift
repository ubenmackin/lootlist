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
            "This quest has log entries. Reward, XP, schedule, and assignee are locked."
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
        guard appState.family != nil else {
            templates = []
            activeAssignments = []
            return
        }
        // Non-nil family: rely on `.onChange(of: cached*)` → `rebuildLists`.
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
                        targetCount: Int = 1,
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
            targetCount: targetCount,
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
                          targetCount: Int = 1,
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
            targetCount: targetCount,
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
                     targetCount: Int = 1,
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
                let fieldsChanged = quest.goldReward != goldReward
                    || quest.xpReward != xpReward
                    || quest.scheduleType != scheduleType
                    || quest.targetCount != targetCount
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
        updated.targetCount = targetCount
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
            family: family,
            weekOf: QuestService.startOfWeek(for: Date(), payoutDay: family.payoutDay)
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
        syncTask = Task {
            for await _ in stream {
                // view's `@Query *.Cache` re-fires `.onChange` → `rebuildLists`
                // / `rebuildHeroes`. No explicit `load()`/`loadHeroes()` here —
                // those duplicated the `.onChange` path (and `loadHeroes` was a
                // duplicate of the view's `@Query cachedProfiles`).
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
}
