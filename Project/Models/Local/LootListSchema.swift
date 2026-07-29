//
//  LootListSchema.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import SwiftData

enum LootListSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version {
        Schema.Version(1, 0, 0)
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

enum LootListMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [LootListSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        [] // No migrations yet — V1 is initial
    }
}
