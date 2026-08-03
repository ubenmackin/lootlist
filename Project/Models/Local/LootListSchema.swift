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

enum LootListSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version {
        Schema.Version(2, 0, 0)
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
        [LootListSchemaV1.self, LootListSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [
            // V1 → V2 adds two stored attributes: `QuestCache.xpBanked`
            // (non-optional `Int` with a default of 0) and
            // `QuestCompletionCache.xpCredited` (optional `Int`, nil default).
            // Both are additive — SwiftData lightweight-migrates new attributes
            // with defaults / optionals, so no custom stage is required (D8:
            // schema bump is the sanctioned path for stored-attribute changes).
            .lightweight(fromVersion: LootListSchemaV1.self, toVersion: LootListSchemaV2.self)
        ]
    }
}
