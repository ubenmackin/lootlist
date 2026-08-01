//
//  BackgroundCacheActor.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import os
import SwiftData

@ModelActor
actor BackgroundCacheActor {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "BackgroundCacheActor")

    /// Custom initializer that disables SwiftData autosave on the backing
    /// `modelContext`. Uses a parameter label (`container:`) distinct from the
    /// `@ModelActor`-synthesized `init(modelContainer:)` to avoid an ambiguous
    /// overload diagnostic. This is the single source of truth for autosave
    /// disposition — method bodies no longer toggle `autosaveEnabled`.
    init(container: ModelContainer) {
        modelContainer = container
        let modelContext = ModelContext(container)
        modelContext.autosaveEnabled = false
        modelExecutor = DefaultSerialModelExecutor(modelContext: modelContext)
    }

    // MARK: - Generic batch helpers

    // changeTag is copied unconditionally — nil is a meaningful "no further tag" value that must propagate.

    /// Generic upsert shared by every `batchUpsert*` wrapper. Fetches existing
    /// rows via `T.fetchDescriptor`, keys them by `recordName`, then updates or
    /// inserts each item. The field-for-field merge lives in each type's
    /// `CacheMergeable.update(from:)` — explicit and type-safe, no reflection.
    private func batchUpsert<T: CacheMergeable>(
        _: T.Type,
        _ items: [T.DomainModel],
        familyRecordName: String?
    ) {
        let existing = (try? modelContext.fetch(T.fetchDescriptor(familyRecordName: familyRecordName))) ?? []
        let byName = Dictionary(uniqueKeysWithValues: existing.map { ($0.recordName, $0) })
        for item in items {
            let name = item.id.recordName
            if let target = byName[name] {
                target.update(from: item)
            } else {
                modelContext.insert(T(from: item))
            }
        }
        saveContext()
    }

    /// Generic purge shared by every `purgeMissing*` wrapper. Deletes any cached
    /// row whose `recordName` is absent from `validRecordNames`, scoped by
    /// `familyRecordName` via `T.fetchDescriptor`.
    private func purgeMissing<T: CacheMergeable>(
        _: T.Type,
        validRecordNames: Set<String>,
        familyRecordName: String?
    ) {
        let existing = (try? modelContext.fetch(T.fetchDescriptor(familyRecordName: familyRecordName))) ?? []
        for cached in existing where !validRecordNames.contains(cached.recordName) {
            modelContext.delete(cached)
        }
        saveContext()
    }

    // MARK: - Batch upserts (public API preserved as thin wrappers)

    func batchUpsertQuests(_ quests: [Quest], familyRecordName: String? = nil) {
        batchUpsert(QuestCache.self, quests, familyRecordName: familyRecordName)
    }

    func batchUpsertProfiles(_ profiles: [Profile], familyRecordName: String? = nil) {
        batchUpsert(ProfileCache.self, profiles, familyRecordName: familyRecordName)
    }

    func batchUpsertQuestCompletions(_ completions: [QuestCompletion], familyRecordName: String? = nil) {
        batchUpsert(QuestCompletionCache.self, completions, familyRecordName: familyRecordName)
    }

    func batchUpsertQuestTemplates(_ templates: [QuestTemplate], familyRecordName: String? = nil) {
        batchUpsert(QuestTemplateCache.self, templates, familyRecordName: familyRecordName)
    }

    func batchUpsertLedgerEntries(_ entries: [LedgerEntry], familyRecordName: String? = nil) {
        batchUpsert(LedgerEntryCache.self, entries, familyRecordName: familyRecordName)
    }

    func batchUpsertAllowancePeriods(_ periods: [AllowancePeriod], familyRecordName: String? = nil) {
        batchUpsert(AllowancePeriodCache.self, periods, familyRecordName: familyRecordName)
    }

    func batchUpsertAchievements(_ achievements: [Achievement], familyRecordName: String? = nil) {
        batchUpsert(AchievementCache.self, achievements, familyRecordName: familyRecordName)
    }

    func batchUpsertProfileAchievements(_ pas: [ProfileAchievement], familyRecordName: String? = nil) {
        batchUpsert(ProfileAchievementCache.self, pas, familyRecordName: familyRecordName)
    }

    func batchUpsertFamilies(_ families: [Family]) {
        batchUpsert(FamilyCache.self, families, familyRecordName: nil)
    }

    func batchUpsertNotificationPreferences(_ prefs: [NotificationPreference], familyRecordName: String? = nil) {
        batchUpsert(NotificationPreferenceCache.self, prefs, familyRecordName: familyRecordName)
    }

    // MARK: - Purges (public API preserved as thin wrappers)

    func purgeMissingQuests(validRecordNames: Set<String>, familyRecordName: String? = nil) {
        purgeMissing(QuestCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
    }

    func purgeMissingProfiles(validRecordNames: Set<String>, familyRecordName: String? = nil) {
        purgeMissing(ProfileCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
    }

    func purgeMissingQuestCompletions(validRecordNames: Set<String>, familyRecordName: String? = nil) {
        purgeMissing(QuestCompletionCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
    }

    func purgeMissingQuestTemplates(validRecordNames: Set<String>, familyRecordName: String? = nil) {
        purgeMissing(QuestTemplateCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
    }

    func purgeMissingLedgerEntries(validRecordNames: Set<String>, familyRecordName: String? = nil) {
        purgeMissing(LedgerEntryCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
    }

    func purgeMissingAllowancePeriods(validRecordNames: Set<String>, familyRecordName: String? = nil) {
        purgeMissing(AllowancePeriodCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
    }

    func purgeMissingAchievements(validRecordNames: Set<String>, familyRecordName: String? = nil) {
        purgeMissing(AchievementCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
    }

    func purgeMissingProfileAchievements(validRecordNames: Set<String>, familyRecordName: String? = nil) {
        purgeMissing(ProfileAchievementCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
    }

    func purgeMissingFamilies(validRecordNames: Set<String>) {
        purgeMissing(FamilyCache.self, validRecordNames: validRecordNames, familyRecordName: nil)
    }

    func purgeMissingNotificationPreferences(validRecordNames: Set<String>, familyRecordName: String? = nil) {
        purgeMissing(NotificationPreferenceCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
    }

    /// Backfills `targetCount` to `1` for any `QuestCache` or `QuestTemplateCache`
    /// rows where the value is nil/zero/unset. Runs globally across all families
    /// by `@Attribute(.unique) recordName` — this is a one-time migration for
    /// pre-`targetCount` installs whose cache was persisted before the field
    /// existed. New rows always carry the `targetCount = 1` default from their
    /// `init`, so they are left untouched. Idempotent: rows already carrying a
    /// positive `targetCount` are never clobbered.
    func backfillTargetCountGlobally() {
        // QuestCache — iterate by recordName (global, not per-family).
        let quests = (try? modelContext.fetch(FetchDescriptor<QuestCache>())) ?? []
        for quest in quests where quest.targetCount <= 0 {
            quest.targetCount = 1
        }

        // QuestTemplateCache — same global-by-recordName iteration.
        let templates = (try? modelContext.fetch(FetchDescriptor<QuestTemplateCache>())) ?? []
        for template in templates where template.targetCount <= 0 {
            template.targetCount = 1
        }

        saveContext()
    }

    func deleteRecord(recordName: String, type: CachedRecordType) {
        switch type {
        case .profile: deleteRecordByRecordName(ProfileCache.self, recordName: recordName)
        case .family: deleteRecordByRecordName(FamilyCache.self, recordName: recordName)
        case .quest: deleteRecordByRecordName(QuestCache.self, recordName: recordName)
        case .questTemplate: deleteRecordByRecordName(QuestTemplateCache.self, recordName: recordName)
        case .questCompletion: deleteRecordByRecordName(QuestCompletionCache.self, recordName: recordName)
        case .ledgerEntry: deleteRecordByRecordName(LedgerEntryCache.self, recordName: recordName)
        case .allowancePeriod: deleteRecordByRecordName(AllowancePeriodCache.self, recordName: recordName)
        case .achievement: deleteRecordByRecordName(AchievementCache.self, recordName: recordName)
        case .profileAchievement: deleteRecordByRecordName(ProfileAchievementCache.self, recordName: recordName)
        case .notificationPreference: deleteRecordByRecordName(NotificationPreferenceCache.self, recordName: recordName)
        }
        saveContext()
    }

    /// Generic single-record delete shared by every `deleteRecord` route. Rows
    /// are fetched through the type's `recordName`-scoped `fetchDescriptor`,
    /// which predicates on the unique `@Attribute(.unique) recordName` so the
    /// lookup uses the unique attribute's implicit index instead of pulling the
    /// full table and filtering in memory. `#Predicate` cannot be written
    /// generically, so each conformance provides its own descriptor.
    private func deleteRecordByRecordName<T: CacheMergeable>(_: T.Type, recordName: String) {
        let match = (try? modelContext.fetch(T.fetchDescriptor(recordName: recordName)))?.first
        if let match {
            modelContext.delete(match)
        }
    }

    private func saveContext() {
        do {
            try modelContext.save()
        } catch {
            logger.error("Failed to save background context: \(error, privacy: .private)")
        }
    }
}
