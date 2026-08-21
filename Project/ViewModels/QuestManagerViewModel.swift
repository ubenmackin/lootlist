//
//  QuestManagerViewModel.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import Observation
import OSLog

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
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "QuestManagerVM")
    private(set) var templates: [QuestTemplateCache] = []

    private(set) var activeAssignments: [QuestCache] = []

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

    struct QuickQuestInput {
        var name: String
        var description: String
        var assignee: Profile
        var goldReward: Double
        var xpReward: Int
        var scheduleType: QuestSchedule
        var specificDays: [String] = []
        var targetCount: Int = 1
        var approvalMode: ApprovalMode
        var weekOf: Date
    }

    struct UpdateQuestInput {
        var name: String?
        var descriptionText: String?
        var goldReward: Double
        var xpReward: Int
        var scheduleType: QuestSchedule
        var specificDays: [String] = []
        var targetCount: Int = 1
        var isAllOrNothing: Bool
        var approvalMode: ApprovalMode
        var assignee: Profile
        var allowLockedFieldsOverride: Bool = false
        var propagateToTemplate: Bool = false
    }

    func assignQuickQuest(_ input: QuickQuestInput) async throws {
        guard let parent = appState.currentProfile,
              let family = appState.family
        else {
            throw QuestServiceError.missingSession
        }
        _ = try await questService.assignQuickQuest(
            name: input.name,
            description: input.description,
            assignee: input.assignee,
            goldReward: input.goldReward,
            xpReward: input.xpReward,
            scheduleType: input.scheduleType,
            specificDays: input.specificDays,
            targetCount: input.targetCount,
            approvalMode: input.approvalMode,
            weekOf: input.weekOf,
            createdBy: parent,
            family: family
        )
    }

    func updateQuest(_ quest: Quest, input: UpdateQuestInput) async throws {
        guard appState.family != nil else {
            throw QuestServiceError.missingSession
        }

        // If quest has logs, only name and descriptionText may change
        if !input.allowLockedFieldsOverride {
            let logs = try await questService.fetchQuestLogs(forQuest: quest)
            if !logs.isEmpty {
                let fieldsChanged = quest.goldReward != input.goldReward
                    || quest.xpReward != input.xpReward
                    || quest.scheduleType != input.scheduleType
                    || quest.targetCount != input.targetCount
                    || quest.assignee.recordID != input.assignee.id
                    || quest.isAllOrNothing != input.isAllOrNothing
                if fieldsChanged {
                    throw QuestEditLockedError.lockedFields
                }
            }
        }

        var updated = quest
        updated.name = input.name
        updated.descriptionText = input.descriptionText
        updated.goldReward = input.goldReward
        updated.xpReward = input.xpReward
        updated.scheduleType = input.scheduleType
        updated.targetCount = input.targetCount
        updated.isAllOrNothing = input.isAllOrNothing
        updated.approvalMode = input.approvalMode
        updated.assignee = CKRecord.Reference(recordID: input.assignee.id, action: .none)

        _ = try await questService.updateQuest(updated)

        let zoneID = quest.id.zoneID
        if input.propagateToTemplate, let templateCache = templates.first(where: { $0.recordName == quest.template.recordID.recordName }) {
            var template = templateCache.toQuestTemplate(zoneID: zoneID)
            template.scheduleType = input.scheduleType
            template.specificDays = input.scheduleType.requiresSpecificDays ? input.specificDays : []
            do {
                _ = try await questService.updateTemplate(template)
            } catch {
                logger.error("Failed to propagate template update: \(error, privacy: .private)")
            }
        }
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
        let allCompletions: [QuestCompletion]
        do {
            allCompletions = try await questService.fetchQuestCompletionsForFamily(family: family)
        } catch {
            logger.warning("Failed to fetch quest completions for family: \(error, privacy: .private)")
            allCompletions = []
        }

        var completionsByQuest: [String: [QuestCompletion]] = [:]
        for completion in allCompletions {
            completionsByQuest[completion.quest.recordID.recordName, default: []].append(completion)
        }

        // Collect all pending completions across quests in descending date order.
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
}
