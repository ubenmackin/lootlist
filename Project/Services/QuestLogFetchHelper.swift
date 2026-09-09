//
//  QuestLogFetchHelper.swift
//  LootList
//
//  Created by Ben Mackin on 9/8/26.
//

import CloudKit
import Foundation

@MainActor
enum QuestLogFetchHelper {
    static func fetchQuestLogs(
        forQuest quest: Quest,
        useCache: Bool = true,
        appState: AppState,
        cacheService: any CacheServicing,
        cloudKit: any CloudKitServiceProtocol,
        syncCoordinator: any SyncEnqueuing
    ) async throws -> [QuestCompletion] {
        if !useCache {
            // WHY fail-closed: unknown scope drops hydrate instead of guessing a database.
            guard let scope = DatabaseScopeResolver.resolvedScope(appState: appState) else {
                throw QuestServiceError.missingSession
            }
            let questRef = CKRecord.Reference(recordID: quest.id, action: .none)
            let predicate = NSPredicate(format: "quest == %@", questRef)
            let all = try await cloudKit.query(
                QuestCompletion.self,
                predicate: predicate,
                in: quest.id.zoneID,
                sortDescriptors: [NSSortDescriptor(key: "completedDate", ascending: false)]
            )
            await syncCoordinator.hydrationHandler.hydrateFromQuery(
                models: all,
                databaseScope: scope,
                zoneID: quest.id.zoneID
            )
            return all
        }
        let family = Family(
            name: "",
            creatorUserRecordName: nil,
            id: CKRecord.ID(recordName: quest.family.recordID.recordName, zoneID: quest.id.zoneID)
        )
        // WHY fail-closed: unknown scope serves cache only without guessing a database.
        guard let scope = DatabaseScopeResolver.resolvedScope(appState: appState) else {
            return cacheService.fetchQuestCompletions(family: family.id.recordName)
                .filter { $0.questRecordName == quest.id.recordName }
                .map { cache in cache.toQuestCompletion(zoneID: quest.id.zoneID) }
                .sorted { $0.completedDate > $1.completedDate }
        }
        return try await CacheFirst.cacheFirst(
            type: .questCompletion,
            family: family,
            cacheService: cacheService,
            scope: scope,
            operations: .init(
                fetchCache: { familyName in
                    cacheService.fetchQuestCompletions(family: familyName)
                        .filter { $0.questRecordName == quest.id.recordName }
                },
                map: { cache in
                    cache.toQuestCompletion(zoneID: quest.id.zoneID)
                },
                query: {
                    let questRef = CKRecord.Reference(recordID: quest.id, action: .none)
                    let predicate = NSPredicate(format: "quest == %@", questRef)
                    return try await cloudKit.query(
                        QuestCompletion.self,
                        predicate: predicate,
                        in: quest.id.zoneID,
                        sortDescriptors: [NSSortDescriptor(key: "completedDate", ascending: false)]
                    )
                },
                hydrate: { models in
                    await syncCoordinator.hydrationHandler.hydrateFromQuery(
                        models: models,
                        databaseScope: scope,
                        zoneID: quest.id.zoneID
                    )
                },
                sortedBy: { $0.completedDate > $1.completedDate }
            )
        )
    }
}
