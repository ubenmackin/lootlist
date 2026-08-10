//
//  CacheService.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import os
import SwiftData
import Synchronization

@MainActor
@Observable
final class CacheService {
    let container: ModelContainer?
    var initializationError: Error?

    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "CacheService")
    private var isBatching = false

    /// Shared in-flight mutation registry. Mutation services
    /// register a `recordName` before their optimistic upsert and deregister it
    /// once the CloudKit save settles (success or terminal failure);
    /// `BackgroundCacheActor.batchUpsert*` consults this same instance so a
    /// background sync never clobbers an optimistically-written row with stale
    /// server data. `@ObservationIgnored` because it is shared concurrency
    /// infrastructure, not observable UI state.
    @ObservationIgnored
    let inFlightRegistry = InFlightMutationRegistry()

    // Test-only observation hook: records the `family` scope of every
    // `fetchLedgerEntries(profileRecordName:family:)` call so tests can assert
    // a mutation's optimistic snapshot and rollback re-fetch stay scoped to
    // the active family. Production code never reads this; it exists so the
    // family-scoping of the ledger snapshot can be verified rather than
    // inferred from cache contents (the snapshot is keyed by a freshly
    // generated record name, which no pre-existing row can match).
    // `@ObservationIgnored` because it is test infrastructure, not
    // observable UI state. Compiled out of release builds so a shipped app
    // never allocates it; it is only ever appended to and reset by
    // debug-build tests.
    #if DEBUG
        @ObservationIgnored
        var ledgerEntryFetchScopes: [String?] = []
    #endif

    /// Cancellable handle for the `ModelContext.didSave` observer task.
    /// Wrapped in a `Mutex` so `nonisolated deinit` can cancel the
    /// listener without touching main-actor-isolated state (same pattern as
    /// SyncEngine's sync task mutex).
    private let didSaveObserverMutex = Mutex<Task<Void, Never>?>(nil)

    /// Shorthand for `container.mainContext`. Used by every read/write on this
    /// service so the underlying access path lives in one place.
    var context: ModelContext? {
        container?.mainContext
    }

    init(inMemory: Bool = false) throws {
        let schema = Schema(LootListSchemaV5.models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        do {
            container = try ModelContainer(
                for: schema,
                migrationPlan: LootListMigrationPlan.self,
                configurations: config
            )
        } catch {
            logger.error("Failed to create ModelContainer: \(error)")
            container = nil
            initializationError = error
        }
        installDidSaveObserver()
    }

    nonisolated deinit {
        didSaveObserverMutex.withLock { $0?.cancel() }
    }

    /// Installs the didSave observer: observes every `ModelContext.didSave` and,
    /// when the saved context is a background context of this container, forces
    /// `container.mainContext` to re-evaluate so `@Query` results update
    /// deterministically even when the OS misses automatic cross-context
    /// propagation. The listener runs as a `@MainActor` task (isolation
    /// inherited from this class), so the hop to main is implicit — no
    /// `@Sendable` closure capture of `self` is involved. Skipped when the
    /// container failed to initialize.
    private func installDidSaveObserver() {
        guard container != nil else { return }
        let task = Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(named: ModelContext.didSave) {
                guard let self,
                      let savedContext = notification.object as? ModelContext else { continue }
                // Main-context saves already re-fire @Query through normal
                // SwiftUI observation; only background-context saves need the
                // deterministic kick. Accessing `savedContext.container` is unsafe
                // across actor boundaries and crashes if `savedContext` is deallocating,
                // so we check pointer inequality against `mainContext`.
                guard savedContext !== container?.mainContext else { continue }
                refreshMainContextAfterBackgroundSave()
            }
        }
        didSaveObserverMutex.withLock { $0 = task }
    }

    /// Forces the main context to incorporate a background save:
    /// `processPendingChanges()` flushes queued remote-change notifications so
    /// `@Query` fetch results re-evaluate deterministically.
    private func refreshMainContextAfterBackgroundSave() {
        guard let container else { return }
        let mainContext = container.mainContext
        mainContext.processPendingChanges()
    }

    func withBatch(_ work: () -> Void) {
        isBatching = true
        defer {
            isBatching = false
            saveContext()
        }
        work()
    }

    /// Saves the model context, throwing on failure.
    func trySaveContext() throws {
        guard let context else { return }
        try context.save()
    }

    /// Saves the model context, logging errors. Returns true on success.
    @discardableResult
    func saveContext() -> Bool {
        guard !isBatching else { return true }
        do {
            try trySaveContext()
            return true
        } catch {
            logger.error("Failed to save context: \(error, privacy: .private)")
            return false
        }
    }

    // MARK: - Freshness Watermark

    private static let freshnessKeyPrefix = "cache_fresh_"

    /// Marks the cache as fully synced for a given family + entity type.
    /// Stored in UserDefaults (not SwiftData) so stamps survive cache purges
    /// and are cheap to read on every cache-first gate. Only SyncEngine writes
    /// stamps — after a successful `batchUpsert*` + `purgeMissing*` pass — so
    /// an absent stamp means "never fully synced" and cache-first reads must
    /// fall through to CloudKit.
    func markCacheFresh(familyRecordName: String, type: CachedRecordType, at date: Date = Date()) {
        UserDefaults.standard.set(date, forKey: freshnessKey(familyRecordName: familyRecordName, type: type))
    }

    /// Returns true when a successful sync pass has stamped this
    /// family + entity type. Absent stamps (never synced) and stamps cleared
    /// by `clearAll()` / `purgeFamily(recordName:)` read as stale.
    func isCacheFresh(familyRecordName: String, type: CachedRecordType) -> Bool {
        UserDefaults.standard.object(forKey: freshnessKey(familyRecordName: familyRecordName, type: type)) != nil
    }

    /// Removes the freshness stamp for one family + type.
    func invalidateFreshness(familyRecordName: String, type: CachedRecordType) {
        UserDefaults.standard.removeObject(forKey: freshnessKey(familyRecordName: familyRecordName, type: type))
    }

    /// Removes every freshness stamp (all families + types). Called by
    /// `clearAll()` so a wiped cache never serves a stale watermark.
    func invalidateAllFreshness() {
        let defaults = UserDefaults.standard
        let staleKeys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(Self.freshnessKeyPrefix) }
        for key in staleKeys {
            defaults.removeObject(forKey: key)
        }
    }

    /// Removes every freshness stamp scoped to a single family. Called by
    /// `purgeFamily(recordName:)` so a purged family never serves a stale
    /// watermark for the rows that were just deleted.
    func invalidateFreshness(forFamilyRecordName familyRecordName: String) {
        let defaults = UserDefaults.standard
        let prefix = "\(Self.freshnessKeyPrefix)\(familyRecordName)_"
        let staleKeys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }
        for key in staleKeys {
            defaults.removeObject(forKey: key)
        }
    }

    private func freshnessKey(familyRecordName: String, type: CachedRecordType) -> String {
        "\(Self.freshnessKeyPrefix)\(familyRecordName)_\(type.rawValue)"
    }

    // MARK: - Private Helpers

    /// Deletes every record matching `predicate` from the given context.
    /// Internal so the `CacheService+Invalidation` extension can cascade-delete
    /// from `purgeFamily(recordName:)`.
    func deleteAll<T: PersistentModel>(
        from context: ModelContext?,
        where predicate: Predicate<T>
    ) {
        guard let context else { return }
        if let items = try? context.fetch(FetchDescriptor<T>(predicate: predicate)) {
            for item in items {
                context.delete(item)
            }
        }
    }

    // changeTag is copied unconditionally — nil is a meaningful "no further tag" value that must propagate.

    // MARK: - Upserts (single)

    // Synchronous @MainActor paths for optimistic UI writes by view models and services.
    // Background sync from CloudKit uses BackgroundCacheActor instead.

    func upsertQuest(_ quest: Quest, family _: String? = nil) {
        guard let context else { return }
        let name = quest.id.recordName
        let descriptor = FetchDescriptor<QuestCache>(
            predicate: #Predicate { $0.recordName == name }
        )
        if let existing = try? context.fetch(descriptor).first {
            QuestCache.apply(existing, from: quest)
        } else {
            context.insert(QuestCache(from: quest))
        }
        saveContext()
    }

    func upsertProfile(_ profile: Profile, family _: String? = nil) {
        guard let context else { return }
        let name = profile.id.recordName
        let descriptor = FetchDescriptor<ProfileCache>(
            predicate: #Predicate { $0.recordName == name }
        )
        if let existing = try? context.fetch(descriptor).first {
            ProfileCache.apply(existing, from: profile)
        } else {
            context.insert(ProfileCache(from: profile))
        }
        saveContext()
    }

    func upsertQuestCompletion(_ completion: QuestCompletion, family _: String? = nil) {
        guard let context else { return }
        let name = completion.id.recordName
        let descriptor = FetchDescriptor<QuestCompletionCache>(
            predicate: #Predicate { $0.recordName == name }
        )
        if let existing = try? context.fetch(descriptor).first {
            QuestCompletionCache.apply(existing, from: completion)
        } else {
            context.insert(QuestCompletionCache(from: completion))
        }
        saveContext()
    }

    func upsertQuestTemplate(_ template: QuestTemplate, family _: String? = nil) {
        guard let context else { return }
        let name = template.id.recordName
        let descriptor = FetchDescriptor<QuestTemplateCache>(
            predicate: #Predicate { $0.recordName == name }
        )
        if let existing = try? context.fetch(descriptor).first {
            QuestTemplateCache.apply(existing, from: template)
        } else {
            context.insert(QuestTemplateCache(from: template))
        }
        saveContext()
    }

    func upsertFamily(_ family: Family) {
        guard let context else { return }
        let name = family.id.recordName
        let descriptor = FetchDescriptor<FamilyCache>(
            predicate: #Predicate { $0.recordName == name }
        )
        if let existing = try? context.fetch(descriptor).first {
            FamilyCache.apply(existing, from: family)
        } else {
            context.insert(FamilyCache(from: family))
        }
        saveContext()
    }

    func upsertLedgerEntry(_ entry: LedgerEntry) {
        guard let context else { return }
        let name = entry.id.recordName
        let descriptor = FetchDescriptor<LedgerEntryCache>(
            predicate: #Predicate { $0.recordName == name }
        )
        if let existing = try? context.fetch(descriptor).first {
            LedgerEntryCache.apply(existing, from: entry)
        } else {
            context.insert(LedgerEntryCache(from: entry))
        }
        saveContext()
    }

    func upsertAllowancePeriod(_ period: AllowancePeriod) {
        guard let context else { return }
        let name = period.id.recordName
        let descriptor = FetchDescriptor<AllowancePeriodCache>(
            predicate: #Predicate { $0.recordName == name }
        )
        if let existing = try? context.fetch(descriptor).first {
            AllowancePeriodCache.apply(existing, from: period)
        } else {
            context.insert(AllowancePeriodCache(from: period))
        }
        saveContext()
    }

    func upsertAchievement(_ achievement: Achievement) {
        guard let context else { return }
        let name = achievement.id.recordName
        let descriptor = FetchDescriptor<AchievementCache>(
            predicate: #Predicate { $0.recordName == name }
        )
        if let existing = try? context.fetch(descriptor).first {
            AchievementCache.apply(existing, from: achievement)
        } else {
            context.insert(AchievementCache(from: achievement))
        }
        saveContext()
    }

    func upsertNotificationPreference(_ pref: NotificationPreference) {
        guard let context else { return }
        let name = pref.id.recordName
        let descriptor = FetchDescriptor<NotificationPreferenceCache>(
            predicate: #Predicate { $0.recordName == name }
        )
        if let existing = try? context.fetch(descriptor).first {
            NotificationPreferenceCache.apply(existing, from: pref)
        } else {
            context.insert(NotificationPreferenceCache(from: pref))
        }
        saveContext()
    }

    func upsertProfileAchievement(_ pa: ProfileAchievement) {
        guard let context else { return }
        let name = pa.id.recordName
        let descriptor = FetchDescriptor<ProfileAchievementCache>(
            predicate: #Predicate { $0.recordName == name }
        )
        if let existing = try? context.fetch(descriptor).first {
            ProfileAchievementCache.apply(existing, from: pa)
        } else {
            context.insert(ProfileAchievementCache(from: pa))
        }
        saveContext()
    }

    // MARK: - Batch Upserts

    private func existingByRecordName<T: CacheMergeable>(_: T.Type, family: String?) -> [String: T] {
        guard let context else { return [:] }
        let descriptor = T.fetchDescriptor(familyRecordName: family)
        let existing = (try? context.fetch(descriptor)) ?? []
        return Dictionary(existing.map { ($0.recordName, $0) }, uniquingKeysWith: { current, _ in current })
    }

    func upsertQuests(_ quests: [Quest], family: String? = nil) {
        guard let context else { return }
        let existingMap = existingByRecordName(QuestCache.self, family: family)
        for quest in quests {
            if let cached = existingMap[quest.id.recordName] {
                QuestCache.apply(cached, from: quest)
            } else {
                context.insert(QuestCache(from: quest))
            }
        }
        saveContext()
    }

    func upsertProfiles(_ profiles: [Profile], family: String? = nil) {
        guard let context else { return }
        let existingMap = existingByRecordName(ProfileCache.self, family: family)
        for profile in profiles {
            if let cached = existingMap[profile.id.recordName] {
                ProfileCache.apply(cached, from: profile)
            } else {
                context.insert(ProfileCache(from: profile))
            }
        }
        saveContext()
    }

    func upsertQuestCompletions(_ completions: [QuestCompletion], family: String? = nil) {
        guard let context else { return }
        let existingMap = existingByRecordName(QuestCompletionCache.self, family: family)
        for completion in completions {
            if let cached = existingMap[completion.id.recordName] {
                QuestCompletionCache.apply(cached, from: completion)
            } else {
                context.insert(QuestCompletionCache(from: completion))
            }
        }
        saveContext()
    }

    func upsertQuestTemplates(_ templates: [QuestTemplate], family: String? = nil) {
        guard let context else { return }
        let existingMap = existingByRecordName(QuestTemplateCache.self, family: family)
        for template in templates {
            if let cached = existingMap[template.id.recordName] {
                QuestTemplateCache.apply(cached, from: template)
            } else {
                context.insert(QuestTemplateCache(from: template))
            }
        }
        saveContext()
    }

    func upsertLedgerEntries(_ entries: [LedgerEntry], family: String? = nil) {
        guard let context else { return }
        let existingMap = existingByRecordName(LedgerEntryCache.self, family: family)
        for entry in entries {
            if let cached = existingMap[entry.id.recordName] {
                LedgerEntryCache.apply(cached, from: entry)
            } else {
                context.insert(LedgerEntryCache(from: entry))
            }
        }
        saveContext()
    }

    func upsertAllowancePeriods(_ periods: [AllowancePeriod], family: String? = nil) {
        guard let context else { return }
        let existingMap = existingByRecordName(AllowancePeriodCache.self, family: family)
        for period in periods {
            if let cached = existingMap[period.id.recordName] {
                AllowancePeriodCache.apply(cached, from: period)
            } else {
                context.insert(AllowancePeriodCache(from: period))
            }
        }
        saveContext()
    }

    func upsertAchievements(_ achievements: [Achievement], family: String? = nil) {
        guard let context else { return }
        let existingMap = existingByRecordName(AchievementCache.self, family: family)
        for achievement in achievements {
            if let cached = existingMap[achievement.id.recordName] {
                AchievementCache.apply(cached, from: achievement)
            } else {
                context.insert(AchievementCache(from: achievement))
            }
        }
        saveContext()
    }

    func upsertProfileAchievements(_ pas: [ProfileAchievement], family: String? = nil) {
        guard let context else { return }
        let existingMap = existingByRecordName(ProfileAchievementCache.self, family: family)
        for pa in pas {
            if let cached = existingMap[pa.id.recordName] {
                ProfileAchievementCache.apply(cached, from: pa)
            } else {
                context.insert(ProfileAchievementCache(from: pa))
            }
        }
        saveContext()
    }

    func upsertNotificationPreferences(_ prefs: [NotificationPreference], family: String? = nil) {
        guard let context else { return }
        let existingMap = existingByRecordName(NotificationPreferenceCache.self, family: family)
        for pref in prefs {
            if let cached = existingMap[pref.id.recordName] {
                NotificationPreferenceCache.apply(cached, from: pref)
            } else {
                context.insert(NotificationPreferenceCache(from: pref))
            }
        }
        saveContext()
    }
}
