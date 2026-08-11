//
//  LootListSchema.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import SwiftData

enum LootListSchemaV5: VersionedSchema {
    static var versionIdentifier: Schema.Version {
        Schema.Version(5, 0, 0)
    }

    static var models: [any PersistentModel.Type] {
        [
            FamilyCache.self,
            ProfileCache.self,
            QuestCache.self,
            QuestTemplateCache.self,
            QuestCompletionCache.self,
            AllowancePeriodCache.self,
            LedgerEntryCache.self,
            AchievementCache.self,
            ProfileAchievementCache.self,
            NotificationPreferenceCache.self
        ]
    }
}
