//
//  LootListSchema.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import SwiftData

enum LootListSchemaV7: VersionedSchema {
    static var versionIdentifier: Schema.Version {
        Schema.Version(7, 0, 0)
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
            NotificationPreferenceCache.self,
            GemLedgerCache.self,
            RewardEventCache.self
        ]
    }
}

/// V8 adds the savings-engine model surface (GoalCache, per-profile savings
/// config, ledger bucket attribution, quest claims, profile avatar emoji).
/// Adding a new @Model type is an incompatible SwiftData change, so existing
/// stores are destructively reset and rehydrated from CloudKit by design —
/// no lightweight migration path is attempted.
enum LootListSchemaV8: VersionedSchema {
    static var versionIdentifier: Schema.Version {
        Schema.Version(8, 0, 0)
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
            NotificationPreferenceCache.self,
            GemLedgerCache.self,
            RewardEventCache.self,
            GoalCache.self
        ]
    }
}

typealias LootListSchema = LootListSchemaV8
