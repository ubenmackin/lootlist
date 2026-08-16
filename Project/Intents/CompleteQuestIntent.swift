//
//  CompleteQuestIntent.swift
//  LootList
//
//  Created by Ben Mackin on 8/6/26.
//

import AppIntents
import CloudKit
import Foundation
import os
import SwiftData

struct CompleteQuestIntent: AppIntent, Sendable {
    static let title: LocalizedStringResource = "Complete Quest"
    static let description = IntentDescription("Marks a quest or chore as completed.")

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "CompleteQuestIntent")

    @Parameter(title: "Quest")
    var quest: QuestEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let dep = AppDependencies.shared,
              let profile = dep.appState.currentProfile
        else {
            return .result(dialog: "LootList isn't running. Open the app first.")
        }

        let targetQuestEntity: QuestEntity
        if let provided = quest {
            targetQuestEntity = provided
        } else {
            let suggested = try await QuestEntityQuery().suggestedEntities()
            guard !suggested.isEmpty else {
                return .result(dialog: "You have no active quests to complete!")
            }
            if suggested.count == 1, let single = suggested.first {
                targetQuestEntity = single
            } else {
                throw $quest.needsValueError("Which quest would you like to complete?")
            }
        }

        let zoneID = dep.appState.familyZoneID ?? dep.appState.family?.id.zoneID ?? CKRecordZone.default().zoneID
        let familyName = dep.appState.family?.id.recordName
        let questModel = dep.cacheService?.fetchQuests(family: familyName, weekInRange: nil)
            .first(where: { $0.recordName == targetQuestEntity.id && $0.isActive })?
            .toQuest(zoneID: zoneID)

        guard let questModel else {
            return .result(dialog: "Quest '\(targetQuestEntity.title)' was not found.")
        }

        do {
            _ = try await dep.questService.markComplete(quest: questModel, by: profile)
            return .result(dialog: "Awesome work! Marked '\(targetQuestEntity.title)' as completed.")
        } catch let err as QuestServiceError {
            return .result(dialog: IntentDialog(stringLiteral: err.errorDescription ?? "Could not complete the quest."))
        } catch {
            logger.error("Failed to complete quest: \(error, privacy: .private)")
            return .result(dialog: "Could not complete the quest. Please try again.")
        }
    }
}
