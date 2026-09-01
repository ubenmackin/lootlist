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

/// Schema V8: adds goals, savings config, ledger bucket attribution, and claims.
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

/// Schema V9: adds targetDate, linkURL, and imageURL to GoalCache.
enum LootListSchemaV9: VersionedSchema {
    static var versionIdentifier: Schema.Version {
        Schema.Version(9, 0, 0)
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

/// Schema V10: lightweight index-only migration for LedgerEntryCache.
/// Retains pre-existing base composite index `[\.familyRecordName, \.recordName]`
/// (family-scoping) and adds `[\.familyRecordName, \.profileRecordName, \.date]`
/// and `[\.familyRecordName, \.profileRecordName, \.source, \.date]` to
/// support hasTransferredToday date-range queries without sparse optional columns.
/// `fromBucket`/`toBucket` are sparse optionals excluded from the DB predicate
/// and filtered in-memory on the small indexed subset to avoid table scans.
/// WARNING: Do not add fromBucket/toBucket to any DB index or predicate — sparse optionals not indexed, would force table scan.
/// LedgerEntryCache declares three total indexes; V10 adds the latter two.
/// No new models, no property changes — indexes only.
/// WHY lightweight: adding indexes without properties is eligible for SwiftData
/// lightweight migration when versionIdentifier bumps; V9 stores migrate without
/// destructive reset. Incompatible-schema fallback in CacheService still handles
/// the case where lightweight migration is unavailable by recreating the store.
enum LootListSchemaV10: VersionedSchema {
    static var versionIdentifier: Schema.Version {
        Schema.Version(10, 0, 0)
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

typealias LootListSchema = LootListSchemaV10
