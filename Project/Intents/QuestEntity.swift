//
//  QuestEntity.swift
//  LootList
//
//  Created by Ben Mackin on 8/6/26.
//

import AppIntents
import Foundation
import SwiftData

struct QuestEntity: AppEntity, Sendable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = .init(name: "Quest")

    static let defaultQuery = QuestEntityQuery()

    var id: String
    var title: String
    var rewardText: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(rewardText)"
        )
    }
}

struct QuestEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [QuestEntity] {
        let all = try await fetchActiveQuests()
        return all.filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [QuestEntity] {
        let all = try await fetchActiveQuests()
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return all }

        // Proximity / substring matching against quest title
        let matches = all.filter { quest in
            let titleLower = quest.title.lowercased()
            return titleLower.contains(query) || query.contains(titleLower)
        }

        return matches.isEmpty ? all : matches
    }

    func suggestedEntities() async throws -> [QuestEntity] {
        try await fetchActiveQuests()
    }

    private func fetchActiveQuests() async throws -> [QuestEntity] {
        await MainActor.run {
            // The app must be running so intents dispatch through its services.
            guard let dep = AppDependencies.shared else { return [] }
            let cacheService = dep.cacheService
            let familyName = dep.appState.family?.id.recordName
            let currentProfile = dep.appState.currentProfile
            let profileRecordName = currentProfile?.id.recordName
            // Mirror markComplete authorization: a parent may act on any
            // family quest; everyone else only sees their own assignments.
            let quests = cacheService.fetchQuests(family: familyName)
                .filter { $0.isActive && (currentProfile?.role.isParent == true || $0.assigneeRecordName == profileRecordName) }

            return quests.map { questCache in
                let formattedReward = CurrencyFormatter.string(questCache.goldReward)
                return QuestEntity(
                    id: questCache.recordName,
                    title: questCache.questName,
                    rewardText: formattedReward
                )
            }
        }
    }
}
