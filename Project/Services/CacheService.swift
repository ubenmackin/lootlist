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
    /// listener without touching main-actor-isolated state (the same `Mutex`
    /// pattern used to guard sync-task handles elsewhere in the service layer).
    private let didSaveObserverMutex = Mutex<Task<Void, Never>?>(nil)

    /// Shorthand for `container.mainContext`. Used by every read/write on this
    /// service so the underlying access path lives in one place.
    var context: ModelContext? {
        container?.mainContext
    }

    init(inMemory: Bool = false) throws {
        let schema = Schema(LootListSchemaV6.models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        do {
            container = try ModelContainer(for: schema, migrationPlan: LootListMigrationPlan.self, configurations: config)
        } catch {
            logger.error("Failed to create ModelContainer with migration plan: \(error). Recreating store...")
            if !inMemory {
                let url = config.url
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    logger.warning("Failed to remove store file at \(url.path): \(error)")
                }
                let shmUrl = url.deletingPathExtension().appendingPathExtension("store-shm")
                let walUrl = url.deletingPathExtension().appendingPathExtension("store-wal")
                do {
                    try FileManager.default.removeItem(at: shmUrl)
                } catch {
                    logger.debug("Failed to remove shm file: \(error)")
                }
                do {
                    try FileManager.default.removeItem(at: walUrl)
                } catch {
                    logger.debug("Failed to remove wal file: \(error)")
                }
            }
            do {
                container = try ModelContainer(for: schema, configurations: config)
            } catch {
                logger.error("Failed to recreate ModelContainer: \(error)")
                container = nil
                initializationError = error
            }
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
    /// and are cheap to read on every cache-first gate. Only the CKSyncEngine
    /// sync pipeline writes stamps — after a successful `batchUpsert*` +
    /// `purgeMissing*` pass — so
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

    func invalidateRecord(identity: ScopedRecordIdentity, type: CachedRecordType) {
        guard let context else { return }
        switch type {
        case .profile:
            deleteByIdentity(ProfileCache.self, identity: identity, in: context)
        case .family:
            deleteByIdentity(FamilyCache.self, identity: identity, in: context)
        case .quest:
            deleteByIdentity(QuestCache.self, identity: identity, in: context)
        case .questTemplate:
            deleteByIdentity(QuestTemplateCache.self, identity: identity, in: context)
        case .questCompletion:
            deleteByIdentity(QuestCompletionCache.self, identity: identity, in: context)
        case .ledgerEntry:
            deleteByIdentity(LedgerEntryCache.self, identity: identity, in: context)
        case .allowancePeriod:
            deleteByIdentity(AllowancePeriodCache.self, identity: identity, in: context)
        case .achievement:
            deleteByIdentity(AchievementCache.self, identity: identity, in: context)
        case .profileAchievement:
            deleteByIdentity(ProfileAchievementCache.self, identity: identity, in: context)
        case .notificationPreference:
            deleteByIdentity(NotificationPreferenceCache.self, identity: identity, in: context)
        }
        _ = saveContext()
    }

    private func deleteByIdentity(
        _ type: (some CacheMergeable).Type,
        identity: ScopedRecordIdentity,
        in context: ModelContext
    ) {
        let recordName = identity.recordID.recordName
        if let match = try? context.fetch(type.fetchDescriptor(recordName: recordName)).first {
            if let expectedFamily = identity.familyRecordName, let scoped = match as? any FamilyScopedCache {
                guard scoped.familyRecordName == expectedFamily else {
                    logger.warning("Cache deletion aborted for \(recordName): expected family \(expectedFamily), found \(scoped.familyRecordName)")
                    return
                }
            }
            if let scoped = match as? any FamilyScopedCache {
                if let sourceZone = scoped.sourceZoneName,
                   identity.zoneID.zoneName != CKRecordZone.default().zoneID.zoneName,
                   sourceZone != identity.zoneID.zoneName
                {
                    logger.warning("Cache deletion aborted for \(recordName): expected zone \(identity.zoneID.zoneName), found \(sourceZone)")
                    return
                }
            }
            context.delete(match)
        }
    }

    // changeTag is copied unconditionally — nil is a meaningful "no further tag" value that must propagate.

    // MARK: - Upserts (single)

    // Synchronous @MainActor paths for optimistic UI writes by view models and services.
    // Background sync from CloudKit uses BackgroundCacheActor instead.

    func upsertQuest(_ quest: Quest, family familyRecordName: String? = nil, isServerSync: Bool = false) {
        guard let context else { return }
        let name = quest.id.recordName
        let expectedFamily = familyRecordName ?? quest.family.recordID.recordName
        let descriptor = FetchDescriptor<QuestCache>(
            predicate: #Predicate { $0.recordName == name && $0.familyRecordName == expectedFamily }
        )
        if let existing = try? context.fetch(descriptor).first {
            guard existing.familyRecordName.isEmpty || existing.familyRecordName == expectedFamily else {
                logger.warning("Scope mismatch ignoring upsert for Quest \(name): existing=\(existing.familyRecordName) expected=\(expectedFamily)")
                return
            }
            QuestCache.apply(existing, from: quest, isServerSync: isServerSync)
        } else {
            context.insert(QuestCache(from: quest))
        }
        saveContext()
    }

    func upsertProfile(_ profile: Profile, family familyRecordName: String? = nil, isServerSync: Bool = false) {
        guard let context else { return }
        let name = profile.id.recordName
        let expectedFamily = familyRecordName ?? profile.family.recordID.recordName
        let descriptor = FetchDescriptor<ProfileCache>(
            predicate: #Predicate { $0.recordName == name && $0.familyRecordName == expectedFamily }
        )
        if let existing = try? context.fetch(descriptor).first {
            guard existing.familyRecordName.isEmpty || existing.familyRecordName == expectedFamily else {
                logger.warning("Scope mismatch ignoring upsert for Profile \(name): existing=\(existing.familyRecordName) expected=\(expectedFamily)")
                return
            }
            ProfileCache.apply(existing, from: profile, isServerSync: isServerSync)
        } else {
            context.insert(ProfileCache(from: profile))
        }
        saveContext()
    }

    func upsertQuestCompletion(_ completion: QuestCompletion, family familyRecordName: String? = nil, isServerSync: Bool = false) {
        guard let context else { return }
        let name = completion.id.recordName
        let expectedFamily = familyRecordName ?? completion.family.recordID.recordName
        let descriptor = FetchDescriptor<QuestCompletionCache>(
            predicate: #Predicate { $0.recordName == name && $0.familyRecordName == expectedFamily }
        )
        if let existing = try? context.fetch(descriptor).first {
            guard existing.familyRecordName.isEmpty || existing.familyRecordName == expectedFamily else {
                logger.warning("Scope mismatch ignoring upsert for QuestCompletion \(name): existing=\(existing.familyRecordName) expected=\(expectedFamily)")
                return
            }
            QuestCompletionCache.apply(existing, from: completion, isServerSync: isServerSync)
        } else {
            context.insert(QuestCompletionCache(from: completion))
        }
        saveContext()
    }

    func upsertQuestTemplate(_ template: QuestTemplate, family familyRecordName: String? = nil, isServerSync: Bool = false) {
        guard let context else { return }
        let name = template.id.recordName
        let expectedFamily = familyRecordName ?? template.family.recordID.recordName
        let descriptor = FetchDescriptor<QuestTemplateCache>(
            predicate: #Predicate { $0.recordName == name && $0.familyRecordName == expectedFamily }
        )
        if let existing = try? context.fetch(descriptor).first {
            guard existing.familyRecordName.isEmpty || existing.familyRecordName == expectedFamily else {
                logger.warning("Scope mismatch ignoring upsert for QuestTemplate \(name): existing=\(existing.familyRecordName) expected=\(expectedFamily)")
                return
            }
            QuestTemplateCache.apply(existing, from: template, isServerSync: isServerSync)
        } else {
            context.insert(QuestTemplateCache(from: template))
        }
        saveContext()
    }

    func upsertFamily(_ family: Family, isServerSync: Bool = false) {
        guard let context else { return }
        let name = family.id.recordName
        let descriptor = FetchDescriptor<FamilyCache>(
            predicate: #Predicate { $0.recordName == name }
        )
        if let existing = try? context.fetch(descriptor).first {
            FamilyCache.apply(existing, from: family, isServerSync: isServerSync)
        } else {
            context.insert(FamilyCache(from: family))
        }
        saveContext()
    }

    func upsertLedgerEntry(_ entry: LedgerEntry, family familyRecordName: String? = nil, isServerSync: Bool = false) {
        guard let context else { return }
        let name = entry.id.recordName
        let expectedFamily = familyRecordName ?? entry.family.recordID.recordName
        let descriptor = FetchDescriptor<LedgerEntryCache>(
            predicate: #Predicate { $0.recordName == name && $0.familyRecordName == expectedFamily }
        )
        if let existing = try? context.fetch(descriptor).first {
            guard existing.familyRecordName.isEmpty || existing.familyRecordName == expectedFamily else {
                logger.warning("Scope mismatch ignoring upsert for LedgerEntry \(name): existing=\(existing.familyRecordName) expected=\(expectedFamily)")
                return
            }
            LedgerEntryCache.apply(existing, from: entry, isServerSync: isServerSync)
        } else {
            context.insert(LedgerEntryCache(from: entry))
        }
        saveContext()
    }

    func upsertAllowancePeriod(_ period: AllowancePeriod, family familyRecordName: String? = nil, isServerSync: Bool = false) {
        guard let context else { return }
        let name = period.id.recordName
        let expectedFamily = familyRecordName ?? period.family.recordID.recordName
        let descriptor = FetchDescriptor<AllowancePeriodCache>(
            predicate: #Predicate { $0.recordName == name && $0.familyRecordName == expectedFamily }
        )
        if let existing = try? context.fetch(descriptor).first {
            guard existing.familyRecordName.isEmpty || existing.familyRecordName == expectedFamily else {
                logger.warning("Scope mismatch ignoring upsert for AllowancePeriod \(name): existing=\(existing.familyRecordName) expected=\(expectedFamily)")
                return
            }
            AllowancePeriodCache.apply(existing, from: period, isServerSync: isServerSync)
        } else {
            context.insert(AllowancePeriodCache(from: period))
        }
        saveContext()
    }

    func upsertAchievement(_ achievement: Achievement, family familyRecordName: String? = nil, isServerSync: Bool = false) {
        guard let context else { return }
        let name = achievement.id.recordName
        let expectedFamily = familyRecordName ?? achievement.family.recordID.recordName
        let descriptor = FetchDescriptor<AchievementCache>(
            predicate: #Predicate { $0.recordName == name && $0.familyRecordName == expectedFamily }
        )
        if let existing = try? context.fetch(descriptor).first {
            guard existing.familyRecordName.isEmpty || existing.familyRecordName == expectedFamily else {
                logger.warning("Scope mismatch ignoring upsert for Achievement \(name): existing=\(existing.familyRecordName) expected=\(expectedFamily)")
                return
            }
            AchievementCache.apply(existing, from: achievement, isServerSync: isServerSync)
        } else {
            context.insert(AchievementCache(from: achievement))
        }
        saveContext()
    }

    func upsertNotificationPreference(_ pref: NotificationPreference, family familyRecordName: String? = nil, isServerSync: Bool = false) {
        guard let context else { return }
        let name = pref.id.recordName
        let expectedFamily = familyRecordName ?? pref.family.recordID.recordName
        let descriptor = FetchDescriptor<NotificationPreferenceCache>(
            predicate: #Predicate { $0.recordName == name && $0.familyRecordName == expectedFamily }
        )
        if let existing = try? context.fetch(descriptor).first {
            guard existing.familyRecordName.isEmpty || existing.familyRecordName == expectedFamily else {
                logger.warning("Scope mismatch ignoring upsert for NotificationPreference \(name): existing=\(existing.familyRecordName) expected=\(expectedFamily)")
                return
            }
            NotificationPreferenceCache.apply(existing, from: pref, isServerSync: isServerSync)
        } else {
            context.insert(NotificationPreferenceCache(from: pref))
        }
        saveContext()
    }

    func upsertProfileAchievement(_ pa: ProfileAchievement, family familyRecordName: String? = nil, isServerSync: Bool = false) {
        guard let context else { return }
        let name = pa.id.recordName
        let expectedFamily = familyRecordName ?? pa.family.recordID.recordName
        let descriptor = FetchDescriptor<ProfileAchievementCache>(
            predicate: #Predicate { $0.recordName == name && $0.familyRecordName == expectedFamily }
        )
        if let existing = try? context.fetch(descriptor).first {
            guard existing.familyRecordName.isEmpty || existing.familyRecordName == expectedFamily else {
                logger.warning("Scope mismatch ignoring upsert for ProfileAchievement \(name): existing=\(existing.familyRecordName) expected=\(expectedFamily)")
                return
            }
            ProfileAchievementCache.apply(existing, from: pa, isServerSync: isServerSync)
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
        let targetFamily = family ?? quests.first?.family.recordID.recordName
        let existingMap = existingByRecordName(QuestCache.self, family: targetFamily)
        for quest in quests {
            let expectedFamily = family ?? quest.family.recordID.recordName
            if let cached = existingMap[quest.id.recordName] {
                guard cached.familyRecordName.isEmpty || cached.familyRecordName == expectedFamily else {
                    logger.warning("Scope mismatch ignoring batch upsert for Quest \(quest.id.recordName): existing=\(cached.familyRecordName) expected=\(expectedFamily)")
                    continue
                }
                QuestCache.apply(cached, from: quest)
            } else {
                context.insert(QuestCache(from: quest))
            }
        }
        saveContext()
    }

    func upsertProfiles(_ profiles: [Profile], family: String? = nil) {
        guard let context else { return }
        let targetFamily = family ?? profiles.first?.family.recordID.recordName
        let existingMap = existingByRecordName(ProfileCache.self, family: targetFamily)
        for profile in profiles {
            let expectedFamily = family ?? profile.family.recordID.recordName
            if let cached = existingMap[profile.id.recordName] {
                guard cached.familyRecordName.isEmpty || cached.familyRecordName == expectedFamily else {
                    logger.warning("Scope mismatch ignoring batch upsert for Profile \(profile.id.recordName): existing=\(cached.familyRecordName) expected=\(expectedFamily)")
                    continue
                }
                ProfileCache.apply(cached, from: profile)
            } else {
                context.insert(ProfileCache(from: profile))
            }
        }
        saveContext()
    }

    func upsertQuestCompletions(_ completions: [QuestCompletion], family: String? = nil) {
        guard let context else { return }
        let targetFamily = family ?? completions.first?.family.recordID.recordName
        let existingMap = existingByRecordName(QuestCompletionCache.self, family: targetFamily)
        for completion in completions {
            let expectedFamily = family ?? completion.family.recordID.recordName
            if let cached = existingMap[completion.id.recordName] {
                guard cached.familyRecordName.isEmpty || cached.familyRecordName == expectedFamily else {
                    logger
                        .warning(
                            "Scope mismatch ignoring batch upsert for QuestCompletion \(completion.id.recordName): existing=\(cached.familyRecordName) expected=\(expectedFamily)"
                        )
                    continue
                }
                QuestCompletionCache.apply(cached, from: completion)
            } else {
                context.insert(QuestCompletionCache(from: completion))
            }
        }
        saveContext()
    }

    func upsertQuestTemplates(_ templates: [QuestTemplate], family: String? = nil) {
        guard let context else { return }
        let targetFamily = family ?? templates.first?.family.recordID.recordName
        let existingMap = existingByRecordName(QuestTemplateCache.self, family: targetFamily)
        for template in templates {
            let expectedFamily = family ?? template.family.recordID.recordName
            if let cached = existingMap[template.id.recordName] {
                guard cached.familyRecordName.isEmpty || cached.familyRecordName == expectedFamily else {
                    logger
                        .warning("Scope mismatch ignoring batch upsert for QuestTemplate \(template.id.recordName): existing=\(cached.familyRecordName) expected=\(expectedFamily)")
                    continue
                }
                QuestTemplateCache.apply(cached, from: template)
            } else {
                context.insert(QuestTemplateCache(from: template))
            }
        }
        saveContext()
    }

    func upsertLedgerEntries(_ entries: [LedgerEntry], family: String? = nil) {
        guard let context else { return }
        let targetFamily = family ?? entries.first?.family.recordID.recordName
        let existingMap = existingByRecordName(LedgerEntryCache.self, family: targetFamily)
        for entry in entries {
            let expectedFamily = family ?? entry.family.recordID.recordName
            if let cached = existingMap[entry.id.recordName] {
                guard cached.familyRecordName.isEmpty || cached.familyRecordName == expectedFamily else {
                    logger.warning("Scope mismatch ignoring batch upsert for LedgerEntry \(entry.id.recordName): existing=\(cached.familyRecordName) expected=\(expectedFamily)")
                    continue
                }
                LedgerEntryCache.apply(cached, from: entry)
            } else {
                context.insert(LedgerEntryCache(from: entry))
            }
        }
        saveContext()
    }

    func upsertAllowancePeriods(_ periods: [AllowancePeriod], family: String? = nil) {
        guard let context else { return }
        let targetFamily = family ?? periods.first?.family.recordID.recordName
        let existingMap = existingByRecordName(AllowancePeriodCache.self, family: targetFamily)
        for period in periods {
            let expectedFamily = family ?? period.family.recordID.recordName
            if let cached = existingMap[period.id.recordName] {
                guard cached.familyRecordName.isEmpty || cached.familyRecordName == expectedFamily else {
                    logger
                        .warning("Scope mismatch ignoring batch upsert for AllowancePeriod \(period.id.recordName): existing=\(cached.familyRecordName) expected=\(expectedFamily)")
                    continue
                }
                AllowancePeriodCache.apply(cached, from: period)
            } else {
                context.insert(AllowancePeriodCache(from: period))
            }
        }
        saveContext()
    }

    func upsertAchievements(_ achievements: [Achievement], family: String? = nil) {
        guard let context else { return }
        let targetFamily = family ?? achievements.first?.family.recordID.recordName
        let existingMap = existingByRecordName(AchievementCache.self, family: targetFamily)
        for achievement in achievements {
            let expectedFamily = family ?? achievement.family.recordID.recordName
            if let cached = existingMap[achievement.id.recordName] {
                guard cached.familyRecordName.isEmpty || cached.familyRecordName == expectedFamily else {
                    logger
                        .warning(
                            "Scope mismatch ignoring batch upsert for Achievement \(achievement.id.recordName): existing=\(cached.familyRecordName) expected=\(expectedFamily)"
                        )
                    continue
                }
                AchievementCache.apply(cached, from: achievement)
            } else {
                context.insert(AchievementCache(from: achievement))
            }
        }
        saveContext()
    }

    func upsertProfileAchievements(_ pas: [ProfileAchievement], family: String? = nil) {
        guard let context else { return }
        let targetFamily = family ?? pas.first?.family.recordID.recordName
        let existingMap = existingByRecordName(ProfileAchievementCache.self, family: targetFamily)
        for pa in pas {
            let expectedFamily = family ?? pa.family.recordID.recordName
            if let cached = existingMap[pa.id.recordName] {
                guard cached.familyRecordName.isEmpty || cached.familyRecordName == expectedFamily else {
                    logger
                        .warning("Scope mismatch ignoring batch upsert for ProfileAchievement \(pa.id.recordName): existing=\(cached.familyRecordName) expected=\(expectedFamily)")
                    continue
                }
                ProfileAchievementCache.apply(cached, from: pa)
            } else {
                context.insert(ProfileAchievementCache(from: pa))
            }
        }
        saveContext()
    }

    func upsertNotificationPreferences(_ prefs: [NotificationPreference], family: String? = nil) {
        guard let context else { return }
        let targetFamily = family ?? prefs.first?.family.recordID.recordName
        let existingMap = existingByRecordName(NotificationPreferenceCache.self, family: targetFamily)
        for pref in prefs {
            let expectedFamily = family ?? pref.family.recordID.recordName
            if let cached = existingMap[pref.id.recordName] {
                guard cached.familyRecordName.isEmpty || cached.familyRecordName == expectedFamily else {
                    logger
                        .warning(
                            "Scope mismatch ignoring batch upsert for NotificationPreference \(pref.id.recordName): existing=\(cached.familyRecordName) expected=\(expectedFamily)"
                        )
                    continue
                }
                NotificationPreferenceCache.apply(cached, from: pref)
            } else {
                context.insert(NotificationPreferenceCache(from: pref))
            }
        }
        saveContext()
    }
}
