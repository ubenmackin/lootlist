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

    /// Registry of record names currently under an optimistic mutation.
    /// The app wiring injects the single shared instance (owned by
    /// `CacheService`); a nil registry disables the guard for callers that
    /// construct the actor standalone (unit tests, legacy call sites).
    private var inFlightRegistry: InFlightMutationRegistry?

    /// Custom initializer that disables SwiftData autosave on the backing
    /// `modelContext`. Uses a parameter label (`container:`) distinct from the
    /// `@ModelActor`-synthesized `init(modelContainer:)` to avoid an ambiguous
    /// overload diagnostic. This is the single source of truth for autosave
    /// disposition — method bodies no longer toggle `autosaveEnabled`.
    init(container: ModelContainer, inFlightRegistry: InFlightMutationRegistry? = nil) {
        modelContainer = container
        let modelContext = ModelContext(container)
        modelContext.autosaveEnabled = false
        modelExecutor = DefaultSerialModelExecutor(modelContext: modelContext)
        self.inFlightRegistry = inFlightRegistry
    }

    // MARK: - Generic batch helpers

    // changeTag is copied unconditionally — nil is a meaningful "no further tag" value that must propagate.

    /// Generic upsert shared by every `batchUpsert*` wrapper. Fetches existing
    /// rows via `T.fetchDescriptor`, keys them by `recordName`, then updates or
    /// inserts each item. The field-for-field merge lives in each type's
    /// `CacheMergeable.update(from:)` — explicit and type-safe, no reflection.
    ///
    /// In-flight guard: rows whose `recordName` is currently in the in-flight mutation
    /// registry are skipped. They are the optimistic author's responsibility —
    /// a background sync must not clobber an optimistically-written row with
    /// server data that is stale relative to the in-flight write; the author's
    /// post-save re-upsert reconciles the row once the save settles. The
    /// registry is snapshotted once per batch (one actor hop), not per row.
    private func batchUpsert<T: CacheMergeable>(
        _: T.Type,
        _ items: [T.DomainModel],
        familyRecordName: String?
    ) async {
        let inFlight = await inFlightRegistry?.activeRecordNames() ?? []
        let pending = items.filter { !inFlight.contains($0.id.recordName) }
        let existing: [T]
        do {
            existing = try modelContext.fetch(T.fetchDescriptor(familyRecordName: familyRecordName))
        } catch {
            logger.error("Failed to fetch existing \(T.self, privacy: .public) for batchUpsert: \(error, privacy: .public)")
            existing = []
        }
        let byName = Dictionary(uniqueKeysWithValues: existing.map { ($0.recordName, $0) })
        for item in pending {
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
    ///
    /// In-flight guard: rows whose `recordName` is currently in the in-flight mutation
    /// registry are skipped, mirroring `batchUpsert`. `validRecordNames` is a
    /// CloudKit query snapshot taken at the *start* of the sync pass — a
    /// brand-new record optimistically upserted (and possibly already saved on
    /// the server) while that query was in flight would otherwise be purged as
    /// "missing" even though the server holds it; the optimistic author's
    /// post-save re-upsert reconciles the row once the save settles. The
    /// registry is snapshotted once per purge (one actor hop), not per row.
    private func purgeMissing<T: CacheMergeable>(
        _: T.Type,
        validRecordNames: Set<String>,
        familyRecordName: String?
    ) async {
        // SAFETY GUARD: Never purge existing cached rows if validRecordNames is empty.
        // An empty result set from CKQuery often occurs when record types lack QUERYABLE
        // indexes in CloudKit Development schema or during network fallback. Purging on
        // empty validRecordNames destroys valid local cached data.
        guard !validRecordNames.isEmpty else { return }

        let inFlight = await inFlightRegistry?.activeRecordNames() ?? []
        let existing: [T]
        do {
            existing = try modelContext.fetch(T.fetchDescriptor(familyRecordName: familyRecordName))
        } catch {
            logger.error("Failed to fetch existing \(T.self, privacy: .public) for purgeMissing: \(error, privacy: .public)")
            existing = []
        }
        for cached in existing where !validRecordNames.contains(cached.recordName) && !inFlight.contains(cached.recordName) {
            modelContext.delete(cached)
        }
        saveContext()
    }

    // MARK: - Batch upserts (public API preserved as thin wrappers)

    func batchUpsertQuests(_ quests: [Quest], familyRecordName: String? = nil) async {
        await batchUpsert(QuestCache.self, quests, familyRecordName: familyRecordName)
    }

    /// Backfills `name` on any Quest in `quests` whose `name` is nil by
    /// reading the authoritative template record from CloudKit. Runs in the
    /// background actor so the per-template await does not contend with the
    /// cache-hit read path. Returns a new array with stamped names where
    /// available; callers must use the returned array for subsequent upsert.
    func backfillQuestNames(_ quests: [Quest], cloudKit: any CloudKitServiceProtocol) async -> [Quest] {
        let nameless = quests.filter { $0.name == nil }
        guard !nameless.isEmpty else { return quests }
        let recordNames = Set(nameless.map(\.template.recordID))
        var templatesByID: [CKRecord.ID: QuestTemplate] = [:]
        for recordID in recordNames {
            if let template = try? await cloudKit.fetch(QuestTemplate.self, id: recordID) {
                templatesByID[recordID] = template
            }
        }
        return quests.map { quest in
            guard quest.name == nil, let template = templatesByID[quest.template.recordID] else { return quest }
            var updated = quest
            updated.name = template.name
            return updated
        }
    }

    func batchUpsertProfiles(_ profiles: [Profile], familyRecordName: String? = nil) async {
        await batchUpsert(ProfileCache.self, profiles, familyRecordName: familyRecordName)
    }

    func batchUpsertQuestCompletions(_ completions: [QuestCompletion], familyRecordName: String? = nil) async {
        await batchUpsert(QuestCompletionCache.self, completions, familyRecordName: familyRecordName)
    }

    func batchUpsertQuestTemplates(_ templates: [QuestTemplate], familyRecordName: String? = nil) async {
        await batchUpsert(QuestTemplateCache.self, templates, familyRecordName: familyRecordName)
    }

    func batchUpsertLedgerEntries(_ entries: [LedgerEntry], familyRecordName: String? = nil) async {
        await batchUpsert(LedgerEntryCache.self, entries, familyRecordName: familyRecordName)
    }

    func batchUpsertAllowancePeriods(_ periods: [AllowancePeriod], familyRecordName: String? = nil) async {
        await batchUpsert(AllowancePeriodCache.self, periods, familyRecordName: familyRecordName)
    }

    func batchUpsertAchievements(_ achievements: [Achievement], familyRecordName: String? = nil) async {
        await batchUpsert(AchievementCache.self, achievements, familyRecordName: familyRecordName)
    }

    func batchUpsertProfileAchievements(_ pas: [ProfileAchievement], familyRecordName: String? = nil) async {
        await batchUpsert(ProfileAchievementCache.self, pas, familyRecordName: familyRecordName)
    }

    func batchUpsertFamilies(_ families: [Family]) async {
        await batchUpsert(FamilyCache.self, families, familyRecordName: nil)
    }

    func batchUpsertNotificationPreferences(_ prefs: [NotificationPreference], familyRecordName: String? = nil) async {
        await batchUpsert(NotificationPreferenceCache.self, prefs, familyRecordName: familyRecordName)
    }

    // MARK: - Purges (public API preserved as thin wrappers)

    /// Guards the purge path against a nil or empty `familyRecordName`.
    /// A purge without a concrete family scope could delete another family's
    /// cached rows — a cross-family data-loss hazard. `FamilyCache` is exempt:
    /// it is the root record, never family-scoped, and is always purged globally.
    /// Returns the validated non-empty scope, or nil to short-circuit the purge.
    private func validatedFamilyScope(_ familyRecordName: String?) -> String? {
        guard let familyRecordName, !familyRecordName.isEmpty else {
            logger.warning("Purge skipped: familyRecordName is required, got nil/empty scope")
            return nil
        }
        return familyRecordName
    }

    func purgeMissingQuests(validRecordNames: Set<String>, familyRecordName: String? = nil) async {
        guard let familyRecordName = validatedFamilyScope(familyRecordName) else { return }
        await purgeMissing(QuestCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
    }

    func purgeMissingProfiles(validRecordNames: Set<String>, familyRecordName: String? = nil) async {
        guard let familyRecordName = validatedFamilyScope(familyRecordName) else { return }
        await purgeMissing(ProfileCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
    }

    func purgeMissingQuestCompletions(validRecordNames: Set<String>, familyRecordName: String? = nil) async {
        guard let familyRecordName = validatedFamilyScope(familyRecordName) else { return }
        await purgeMissing(QuestCompletionCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
    }

    func purgeMissingQuestTemplates(validRecordNames: Set<String>, familyRecordName: String? = nil) async {
        guard let familyRecordName = validatedFamilyScope(familyRecordName) else { return }
        await purgeMissing(QuestTemplateCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
    }

    func purgeMissingLedgerEntries(validRecordNames: Set<String>, familyRecordName: String? = nil) async {
        guard let familyRecordName = validatedFamilyScope(familyRecordName) else { return }
        await purgeMissing(LedgerEntryCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
    }

    func purgeMissingAllowancePeriods(validRecordNames: Set<String>, familyRecordName: String? = nil) async {
        guard let familyRecordName = validatedFamilyScope(familyRecordName) else { return }
        await purgeMissing(AllowancePeriodCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
    }

    func purgeMissingAchievements(validRecordNames: Set<String>, familyRecordName: String? = nil) async {
        guard let familyRecordName = validatedFamilyScope(familyRecordName) else { return }
        await purgeMissing(AchievementCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
    }

    func purgeMissingProfileAchievements(validRecordNames: Set<String>, familyRecordName: String? = nil) async {
        guard let familyRecordName = validatedFamilyScope(familyRecordName) else { return }
        await purgeMissing(ProfileAchievementCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
    }

    func purgeMissingFamilies(validRecordNames: Set<String>) async {
        await purgeMissing(FamilyCache.self, validRecordNames: validRecordNames, familyRecordName: nil)
    }

    func purgeMissingNotificationPreferences(validRecordNames: Set<String>, familyRecordName: String? = nil) async {
        guard let familyRecordName = validatedFamilyScope(familyRecordName) else { return }
        await purgeMissing(NotificationPreferenceCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
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
        let quests: [QuestCache]
        do {
            quests = try modelContext.fetch(FetchDescriptor<QuestCache>())
        } catch {
            logger.error("Failed to fetch QuestCache for backfill: \(error, privacy: .public)")
            quests = []
        }
        for quest in quests where quest.targetCount <= 0 {
            quest.targetCount = 1
        }

        // QuestTemplateCache — same global-by-recordName iteration.
        let templates: [QuestTemplateCache]
        do {
            templates = try modelContext.fetch(FetchDescriptor<QuestTemplateCache>())
        } catch {
            logger.error("Failed to fetch QuestTemplateCache for backfill: \(error, privacy: .public)")
            templates = []
        }
        for template in templates where template.targetCount <= 0 {
            template.targetCount = 1
        }

        saveContext()

        // Defense-in-depth: surface any rows that still carry a non-positive targetCount
        // after the backfill sweep. The runtime GoldCalculation.isFullyCompleted guard
        // tolerates a residual zero, but surfacing it here narrows the diagnostic window.
        let zeroQuests: [QuestCache]
        do {
            zeroQuests = try modelContext.fetch(FetchDescriptor<QuestCache>(predicate: #Predicate { $0.targetCount <= 0 }))
        } catch {
            logger.error("Failed to fetch zero-target QuestCache post-backfill: \(error, privacy: .public)")
            zeroQuests = []
        }
        for quest in zeroQuests {
            logger.warning("QuestCache targetCount stuck at zero post-backfill: \(quest.recordName, privacy: .private)")
        }

        let zeroTemplates: [QuestTemplateCache]
        do {
            zeroTemplates = try modelContext.fetch(FetchDescriptor<QuestTemplateCache>(predicate: #Predicate { $0.targetCount <= 0 }))
        } catch {
            logger.error("Failed to fetch zero-target QuestTemplateCache post-backfill: \(error, privacy: .public)")
            zeroTemplates = []
        }
        for template in zeroTemplates {
            logger.warning("QuestTemplateCache targetCount stuck at zero post-backfill: \(template.recordName, privacy: .private)")
        }
        assert(zeroQuests.isEmpty, "QuestCache has zero targetCount post-backfill")
        assert(zeroTemplates.isEmpty, "QuestTemplateCache has zero targetCount post-backfill")
    }

    /// Incremental-sync deletion path. The typed `CachedRecordType`
    /// switch keeps the raw CKRecordType → cache-type divergence resolved in one
    /// place (`CachedRecordType.recordType(for:)`), then delegates to the generic
    /// recordName-scoped delete. Every route shares the same in-flight registry
    /// guard, so no path deletes rows under an active optimistic mutation.
    func deleteRecord(recordName: String, type: CachedRecordType?) async {
        if let type {
            switch type {
            case .profile: await deleteRecordByRecordName(ProfileCache.self, recordName: recordName)
            case .family: await deleteRecordByRecordName(FamilyCache.self, recordName: recordName)
            case .quest: await deleteRecordByRecordName(QuestCache.self, recordName: recordName)
            case .questTemplate: await deleteRecordByRecordName(QuestTemplateCache.self, recordName: recordName)
            case .questCompletion: await deleteRecordByRecordName(QuestCompletionCache.self, recordName: recordName)
            case .ledgerEntry: await deleteRecordByRecordName(LedgerEntryCache.self, recordName: recordName)
            case .allowancePeriod: await deleteRecordByRecordName(AllowancePeriodCache.self, recordName: recordName)
            case .achievement: await deleteRecordByRecordName(AchievementCache.self, recordName: recordName)
            case .profileAchievement: await deleteRecordByRecordName(ProfileAchievementCache.self, recordName: recordName)
            case .notificationPreference: await deleteRecordByRecordName(NotificationPreferenceCache.self, recordName: recordName)
            }
        } else {
            // Unknown-record-type fallback (`type == nil`): the record resolver
            // maps only CKRecordTypes it knows, so this branch runs for deletions
            // the resolver could not map. Sweep every known cache table by
            // recordName as a best-effort heuristic — the record may have been
            // cached under a different type than the server reports, or its type
            // string diverged before the resolver existed.
            //
            // FamilyCache is intentionally excluded from this sweep. It is the
            // root record — never family-scoped, preserved globally, reachable by
            // recordName only from the deliberate `.family` route above. A genuine
            // Family deletion always arrives as `Family.recordType`, which the
            // resolver maps to `.family`, so a record reaching this nil branch can
            // never legitimately be the family row; sweeping it here could only
            // take out the family anchor on a blind name match. The typed path is
            // the single sanctioned route for family-row deletion.
            await deleteRecordByRecordName(QuestCompletionCache.self, recordName: recordName)
            await deleteRecordByRecordName(QuestCache.self, recordName: recordName)
            await deleteRecordByRecordName(QuestTemplateCache.self, recordName: recordName)
            await deleteRecordByRecordName(ProfileCache.self, recordName: recordName)
            await deleteRecordByRecordName(LedgerEntryCache.self, recordName: recordName)
            await deleteRecordByRecordName(AllowancePeriodCache.self, recordName: recordName)
            await deleteRecordByRecordName(AchievementCache.self, recordName: recordName)
            await deleteRecordByRecordName(ProfileAchievementCache.self, recordName: recordName)
            await deleteRecordByRecordName(NotificationPreferenceCache.self, recordName: recordName)
        }
        saveContext()
    }

    /// Generic single-record delete shared by every `deleteRecord` route. Rows
    /// are fetched through the type's `recordName`-scoped `fetchDescriptor`,
    /// which predicates on the unique `@Attribute(.unique) recordName` so the
    /// lookup uses the unique attribute's implicit index instead of pulling the
    /// full table and filtering in memory. `#Predicate` cannot be written
    /// generically, so each conformance provides its own descriptor.
    ///
    /// In-flight guard: rows whose `recordName` is currently in the in-flight mutation
    /// registry are skipped, mirroring `batchUpsert`/`purgeMissing`. A deletion
    /// arriving from an incremental sync while the optimistic author's CloudKit
    /// save is still settling must not delete the cached row mid-mutation — the
    /// author's rollback (or post-save re-upsert) reconciles it once the save
    /// settles, and deleting it first would let the rollback resurrect a record
    /// that no longer exists server-side ("zombie quest"). The registry is
    /// snapshotted once per call (one actor hop), not per row.
    private func deleteRecordByRecordName<T: CacheMergeable>(_: T.Type, recordName: String) async {
        let inFlight = await inFlightRegistry?.activeRecordNames() ?? []
        guard !inFlight.contains(recordName) else { return }
        let match: T?
        do {
            match = try modelContext.fetch(T.fetchDescriptor(recordName: recordName)).first
        } catch {
            logger.error("Failed to fetch \(T.self, privacy: .public) for record deletion (\(recordName, privacy: .private)): \(error, privacy: .public)")
            match = nil
        }
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
