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
    var toastManager: ToastManager?

    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "CacheService")
    private var isBatching = false

    // Test-only hook for asserting ledger fetch family-scoping.
    // Compiled out of release builds.
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
        let schema = Schema(LootListSchemaV7.models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        do {
            container = try ModelContainer(for: schema, configurations: config)
        } catch {
            logger.error("Failed to create ModelContainer; error category=\(Self.errorCategory(error), privacy: .public). Recreating store...")
            if !inMemory {
                let url = config.url
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    logger.warning("Failed to remove store file; error category=\(Self.errorCategory(error), privacy: .public)")
                }
                let shmUrl = url.deletingPathExtension().appendingPathExtension("store-shm")
                let walUrl = url.deletingPathExtension().appendingPathExtension("store-wal")
                do {
                    try FileManager.default.removeItem(at: shmUrl)
                } catch {
                    logger.debug("Failed to remove shm file; error category=\(Self.errorCategory(error), privacy: .public)")
                }
                do {
                    try FileManager.default.removeItem(at: walUrl)
                } catch {
                    logger.debug("Failed to remove wal file; error category=\(Self.errorCategory(error), privacy: .public)")
                }
            }
            do {
                container = try ModelContainer(for: schema, configurations: config)
            } catch {
                logger.error("Failed to recreate ModelContainer; error category=\(Self.errorCategory(error), privacy: .public)")
                container = nil
                initializationError = error
            }
        }
        installDidSaveObserver()
    }

    private static func errorCategory(_ error: Error) -> String {
        String(describing: type(of: error))
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
            toastManager?.show(message: "We couldn't save your changes. Please try again.", type: .error)
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
        do {
            let items = try context.fetch(FetchDescriptor<T>(predicate: predicate))
            for item in items {
                context.delete(item)
            }
        } catch {
            logger.error("Failed to fetch \(T.self, privacy: .public) for deleteAll: \(error, privacy: .private)")
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
        case .gemLedger:
            deleteByIdentity(GemLedgerCache.self, identity: identity, in: context)
        case .rewardEvent:
            deleteByIdentity(RewardEventCache.self, identity: identity, in: context)
        }
        _ = saveContext()
    }

    private func deleteByIdentity(
        _ type: (some CacheMergeable).Type,
        identity: ScopedRecordIdentity,
        in context: ModelContext
    ) {
        let recordName = identity.recordID.recordName
        do {
            guard let match = try context.fetch(type.fetchDescriptor(recordName: recordName)).first else {
                return
            }
            if let expectedFamily = identity.familyRecordName, let scoped = match as? any FamilyScopedCache {
                guard scoped.familyRecordName == expectedFamily else {
                    logger
                        .warning(
                            "Cache deletion aborted for \(recordName, privacy: .private): expected family \(expectedFamily, privacy: .private), found \(scoped.familyRecordName, privacy: .private)"
                        )
                    return
                }
            }
            if let scoped = match as? any FamilyScopedCache {
                if let sourceZone = scoped.sourceZoneName,
                   identity.zoneID.zoneName != CKRecordZone.default().zoneID.zoneName,
                   sourceZone != identity.zoneID.zoneName
                {
                    logger
                        .warning(
                            "Cache deletion aborted for \(recordName, privacy: .private): expected zone \(identity.zoneID.zoneName, privacy: .private), found \(sourceZone, privacy: .private)"
                        )
                    return
                }
            }
            context.delete(match)
        } catch {
            logger.warning("Failed to fetch \(recordName, privacy: .private) for identity deletion: \(error, privacy: .private)")
        }
    }

    private func logFamilyMismatch(
        action: String,
        entityName: String,
        recordName: String,
        requestedFamily: String,
        actualFamily: String
    ) {
        logger.warning(
            """
            \(action, privacy: .public) \(entityName, privacy: .public) \
            \(recordName, privacy: .private): \
            requested=\(requestedFamily, privacy: .private) \
            actual=\(actualFamily, privacy: .private)
            """
        )
    }

    // changeTag is copied unconditionally — nil is a meaningful "no further tag" value that must propagate.

    // MARK: - Upserts (single)

    // Synchronous @MainActor paths for optimistic UI writes by view models and services.
    // Background sync from CloudKit uses BackgroundCacheActor instead.

    private func applyUpsert<T: CacheMergeable>(
        _ domain: T.DomainModel,
        type _: T.Type,
        recordName: String,
        familyRecordName: String?,
        isServerSync: Bool,
        entityName: String
    ) {
        guard let context else { return }
        let descriptor = T.fetchDescriptor(familyRecordName: familyRecordName)
        do {
            if let existing = try context.fetch(descriptor).first(where: { $0.recordName == recordName }) {
                if let familyRecordName,
                   !existing.familyRecordName.isEmpty,
                   existing.familyRecordName != familyRecordName
                {
                    logger
                        .warning(
                            """
                            Scope mismatch ignoring upsert for \(entityName, privacy: .public) \(recordName, privacy: .private): \
                            existing=\(existing.familyRecordName, privacy: .private) expected=\(familyRecordName, privacy: .private)
                            """
                        )
                    return
                }
                T.apply(existing, from: domain, isServerSync: isServerSync)
            } else if let familyRecordName, !familyRecordName.isEmpty {
                // Finding 1 — The family-scoped fetch missed a legacy row with
                // an empty familyRecordName.  Look for it with an unscoped query;
                // update(from:) stamps the correct family scope during apply.
                let unscopedDescriptor = T.fetchDescriptor(familyRecordName: nil)
                if let legacyRow = try context.fetch(unscopedDescriptor)
                    .first(where: { $0.recordName == recordName }),
                    legacyRow.familyRecordName.isEmpty
                {
                    T.apply(legacyRow, from: domain, isServerSync: isServerSync)
                    logger
                        .info(
                            "Repaired empty-family legacy \(entityName, privacy: .public) \(recordName, privacy: .private) → family \(familyRecordName, privacy: .private)"
                        )
                } else {
                    context.insert(T(from: domain))
                }
            } else {
                context.insert(T(from: domain))
            }
        } catch {
            logger.error("Failed to fetch \(entityName, privacy: .public) for upsert \(recordName, privacy: .private): \(error, privacy: .private)")
            return
        }
        saveContext()
    }

    // Finding 2 — Explicit family arguments must match the domain model's own
    // family reference.  A mismatched caller could insert or mutate data under
    // the wrong scope.  Each upsert validates before forwarding to applyUpsert.

    func upsertQuest(_ quest: Quest, family familyRecordName: String? = nil, isServerSync: Bool = false) {
        if let explicit = familyRecordName, explicit != quest.family.recordID.recordName {
            logFamilyMismatch(
                action: "Explicit family mismatch rejecting",
                entityName: "Quest upsert",
                recordName: quest.id.recordName,
                requestedFamily: explicit,
                actualFamily: quest.family.recordID.recordName
            )
            return
        }
        applyUpsert(quest, type: QuestCache.self, recordName: quest.id.recordName,
                    familyRecordName: familyRecordName ?? quest.family.recordID.recordName,
                    isServerSync: isServerSync, entityName: "Quest")
    }

    func upsertProfile(_ profile: Profile, family familyRecordName: String? = nil, isServerSync: Bool = false) {
        if let explicit = familyRecordName, explicit != profile.family.recordID.recordName {
            logFamilyMismatch(
                action: "Explicit family mismatch rejecting",
                entityName: "Profile upsert",
                recordName: profile.id.recordName,
                requestedFamily: explicit,
                actualFamily: profile.family.recordID.recordName
            )
            return
        }
        applyUpsert(profile, type: ProfileCache.self, recordName: profile.id.recordName,
                    familyRecordName: familyRecordName ?? profile.family.recordID.recordName,
                    isServerSync: isServerSync, entityName: "Profile")
    }

    func upsertQuestCompletion(_ completion: QuestCompletion, family familyRecordName: String? = nil, isServerSync: Bool = false) {
        if let explicit = familyRecordName, explicit != completion.family.recordID.recordName {
            logFamilyMismatch(
                action: "Explicit family mismatch rejecting",
                entityName: "QuestCompletion upsert",
                recordName: completion.id.recordName,
                requestedFamily: explicit,
                actualFamily: completion.family.recordID.recordName
            )
            return
        }
        applyUpsert(completion, type: QuestCompletionCache.self, recordName: completion.id.recordName,
                    familyRecordName: familyRecordName ?? completion.family.recordID.recordName,
                    isServerSync: isServerSync, entityName: "QuestCompletion")
    }

    func upsertQuestTemplate(_ template: QuestTemplate, family familyRecordName: String? = nil, isServerSync: Bool = false) {
        if let explicit = familyRecordName, explicit != template.family.recordID.recordName {
            logFamilyMismatch(
                action: "Explicit family mismatch rejecting",
                entityName: "QuestTemplate upsert",
                recordName: template.id.recordName,
                requestedFamily: explicit,
                actualFamily: template.family.recordID.recordName
            )
            return
        }
        applyUpsert(template, type: QuestTemplateCache.self, recordName: template.id.recordName,
                    familyRecordName: familyRecordName ?? template.family.recordID.recordName,
                    isServerSync: isServerSync, entityName: "QuestTemplate")
    }

    func upsertFamily(_ family: Family, isServerSync: Bool = false) {
        applyUpsert(family, type: FamilyCache.self, recordName: family.id.recordName,
                    familyRecordName: nil, isServerSync: isServerSync, entityName: "Family")
    }

    func upsertLedgerEntry(_ entry: LedgerEntry, family familyRecordName: String? = nil, isServerSync: Bool = false) {
        if let explicit = familyRecordName, explicit != entry.family.recordID.recordName {
            logFamilyMismatch(
                action: "Explicit family mismatch rejecting",
                entityName: "LedgerEntry upsert",
                recordName: entry.id.recordName,
                requestedFamily: explicit,
                actualFamily: entry.family.recordID.recordName
            )
            return
        }
        applyUpsert(entry, type: LedgerEntryCache.self, recordName: entry.id.recordName,
                    familyRecordName: familyRecordName ?? entry.family.recordID.recordName,
                    isServerSync: isServerSync, entityName: "LedgerEntry")
    }

    func upsertAllowancePeriod(_ period: AllowancePeriod, family familyRecordName: String? = nil, isServerSync: Bool = false) {
        if let explicit = familyRecordName, explicit != period.family.recordID.recordName {
            logFamilyMismatch(
                action: "Explicit family mismatch rejecting",
                entityName: "AllowancePeriod upsert",
                recordName: period.id.recordName,
                requestedFamily: explicit,
                actualFamily: period.family.recordID.recordName
            )
            return
        }
        applyUpsert(period, type: AllowancePeriodCache.self, recordName: period.id.recordName,
                    familyRecordName: familyRecordName ?? period.family.recordID.recordName,
                    isServerSync: isServerSync, entityName: "AllowancePeriod")
    }

    func upsertAchievement(_ achievement: Achievement, family familyRecordName: String? = nil, isServerSync: Bool = false) {
        if let explicit = familyRecordName, explicit != achievement.family.recordID.recordName {
            logFamilyMismatch(
                action: "Explicit family mismatch rejecting",
                entityName: "Achievement upsert",
                recordName: achievement.id.recordName,
                requestedFamily: explicit,
                actualFamily: achievement.family.recordID.recordName
            )
            return
        }
        applyUpsert(achievement, type: AchievementCache.self, recordName: achievement.id.recordName,
                    familyRecordName: familyRecordName ?? achievement.family.recordID.recordName,
                    isServerSync: isServerSync, entityName: "Achievement")
    }

    func upsertNotificationPreference(_ pref: NotificationPreference, family familyRecordName: String? = nil, isServerSync: Bool = false) {
        if let explicit = familyRecordName, explicit != pref.family.recordID.recordName {
            logFamilyMismatch(
                action: "Explicit family mismatch rejecting",
                entityName: "NotificationPreference upsert",
                recordName: pref.id.recordName,
                requestedFamily: explicit,
                actualFamily: pref.family.recordID.recordName
            )
            return
        }
        applyUpsert(pref, type: NotificationPreferenceCache.self, recordName: pref.id.recordName,
                    familyRecordName: familyRecordName ?? pref.family.recordID.recordName,
                    isServerSync: isServerSync, entityName: "NotificationPreference")
    }

    func upsertGemLedger(_ entry: GemLedger, family familyRecordName: String? = nil, isServerSync: Bool = false) {
        if let explicit = familyRecordName, explicit != entry.family.recordID.recordName {
            logFamilyMismatch(
                action: "Explicit family mismatch rejecting",
                entityName: "GemLedger upsert",
                recordName: entry.id.recordName,
                requestedFamily: explicit,
                actualFamily: entry.family.recordID.recordName
            )
            return
        }
        applyUpsert(entry, type: GemLedgerCache.self, recordName: entry.id.recordName,
                    familyRecordName: familyRecordName ?? entry.family.recordID.recordName,
                    isServerSync: isServerSync, entityName: "GemLedger")
    }

    func upsertRewardEvent(_ event: RewardEvent, family familyRecordName: String? = nil, isServerSync: Bool = false) {
        if let explicit = familyRecordName, explicit != event.family.recordID.recordName {
            logFamilyMismatch(
                action: "Explicit family mismatch rejecting",
                entityName: "RewardEvent upsert",
                recordName: event.id.recordName,
                requestedFamily: explicit,
                actualFamily: event.family.recordID.recordName
            )
            return
        }
        applyUpsert(event, type: RewardEventCache.self, recordName: event.id.recordName,
                    familyRecordName: familyRecordName ?? event.family.recordID.recordName,
                    isServerSync: isServerSync, entityName: "RewardEvent")
    }

    /// Applies the server-accepted balance and its immutable debit in one
    /// cache save. The server operation is authoritative; this method only
    /// reconciles the local read store after that operation succeeds.
    func applyGemDebit(profile: Profile, ledger: GemLedger) {
        withBatch {
            upsertProfile(profile, isServerSync: true)
            upsertGemLedger(ledger, isServerSync: true)
        }
    }

    func upsertProfileAchievement(_ pa: ProfileAchievement, family familyRecordName: String? = nil, isServerSync: Bool = false) {
        if let explicit = familyRecordName, explicit != pa.family.recordID.recordName {
            logFamilyMismatch(
                action: "Explicit family mismatch rejecting",
                entityName: "ProfileAchievement upsert",
                recordName: pa.id.recordName,
                requestedFamily: explicit,
                actualFamily: pa.family.recordID.recordName
            )
            return
        }
        applyUpsert(pa, type: ProfileAchievementCache.self, recordName: pa.id.recordName,
                    familyRecordName: familyRecordName ?? pa.family.recordID.recordName,
                    isServerSync: isServerSync, entityName: "ProfileAchievement")
    }

    // MARK: - Batch Upserts

    /// Returns all cached rows keyed by `recordName`.  When `family` is
    /// non-nil the primary fetch is scoped to that family, but empty-family
    /// legacy rows are **also** included so the batch upsert loop can repair
    /// them via `update(from:)` instead of inserting duplicates (Finding 1).
    private func existingByRecordName<T: CacheMergeable>(
        _: T.Type,
        family: String?
    ) -> [String: T]? {
        guard let context else { return nil }
        do {
            let descriptor = T.fetchDescriptor(familyRecordName: family)
            var existing = try context.fetch(descriptor)

            // Finding 1 — Pull in empty-family legacy rows that the
            // family-scoped fetch misses.  The batch upsert loop already
            // tolerates `familyRecordName.isEmpty` and `update(from:)`
            // stamps the correct family during apply.
            if let family, !family.isEmpty {
                let unscopedDescriptor = T.fetchDescriptor(familyRecordName: nil)
                let allRows = try context.fetch(unscopedDescriptor)
                for row in allRows where row.familyRecordName.isEmpty {
                    existing.append(row)
                }
            }

            return Dictionary(
                existing.map { ($0.recordName, $0) },
                uniquingKeysWith: { current, _ in current }
            )
        } catch {
            logger.error(
                """
                Failed to fetch \(String(describing: T.self), privacy: .public) \
                by record name: \(error, privacy: .private)
                """
            )
            return nil
        }
    }

    // Finding 3 — Batch upserts must not derive the lookup scope from only
    // the first item.  Mixed-family batches are grouped by domain family so
    // each group gets its own existing-record map.  An explicit `family`
    // argument scopes all items to that family; items whose domain family
    // disagrees are rejected (Finding 2).
    //
    // Finding 13 — The nine batch upsert implementations below duplicate
    // the same scope, validation, merge, and insert logic.  The generic
    // `batchUpsertByFamily` helper extracts the shared boilerplate while
    // each public method supplies only the per-type closures.

    /// Generic batch upsert shared by every `upsert*` batch wrapper.
    ///
    /// When `family` is nil, items are grouped by their domain family and
    /// this method recurses once per group (Finding 3).  Each item is
    /// validated against the explicit family scope (Finding 2), merged via
    /// `apply` when a cached row exists, or inserted as a new row.
    private func batchUpsertByFamily<T: CacheMergeable>(
        _ items: [T.DomainModel],
        family: String?,
        entityName: String,
        recordName: (T.DomainModel) -> String,
        familyOf: (T.DomainModel) -> String,
        apply: (T.DomainModel, T) -> Void
    ) {
        if family == nil {
            let grouped = Dictionary(grouping: items) { familyOf($0) }
            for (familyName, group) in grouped {
                batchUpsertByFamily(
                    group,
                    family: familyName,
                    entityName: entityName,
                    recordName: recordName,
                    familyOf: familyOf,
                    apply: apply
                )
            }
            return
        }
        guard let family, let context else { return }
        guard let existingMap = existingByRecordName(T.self, family: family) else {
            return
        }
        for item in items {
            let itemName = recordName(item)
            guard familyOf(item) == family else {
                logFamilyMismatch(
                    action: "Explicit family mismatch ignoring batch upsert for",
                    entityName: entityName,
                    recordName: itemName,
                    requestedFamily: family,
                    actualFamily: familyOf(item)
                )
                continue
            }
            if let cached = existingMap[itemName] {
                guard cached.familyRecordName.isEmpty
                    || cached.familyRecordName == family
                else {
                    logger.warning(
                        """
                        Scope mismatch ignoring batch upsert for \
                        \(entityName, privacy: .public) \
                        \(itemName, privacy: .private): \
                        existing=\(cached.familyRecordName, privacy: .private) \
                        expected=\(family, privacy: .private)
                        """
                    )
                    continue
                }
                apply(item, cached)
            } else {
                context.insert(T(from: item))
            }
        }
        saveContext()
    }

    // Finding 3 — Each public batch wrapper handles the nil-family grouping
    // at the top level, then delegates the per-item scope validation, lookup,
    // merge, and insert to the generic helper above.

    func upsertQuests(
        _ quests: [Quest],
        family: String? = nil
    ) {
        batchUpsertByFamily(
            quests,
            family: family,
            entityName: "Quest",
            recordName: { $0.id.recordName },
            familyOf: { $0.family.recordID.recordName },
            apply: { QuestCache.apply($1, from: $0) }
        )
    }

    func upsertProfiles(
        _ profiles: [Profile],
        family: String? = nil
    ) {
        batchUpsertByFamily(
            profiles,
            family: family,
            entityName: "Profile",
            recordName: { $0.id.recordName },
            familyOf: { $0.family.recordID.recordName },
            apply: { ProfileCache.apply($1, from: $0) }
        )
    }

    func upsertQuestCompletions(
        _ completions: [QuestCompletion],
        family: String? = nil
    ) {
        batchUpsertByFamily(
            completions,
            family: family,
            entityName: "QuestCompletion",
            recordName: { $0.id.recordName },
            familyOf: { $0.family.recordID.recordName },
            apply: { QuestCompletionCache.apply($1, from: $0) }
        )
    }

    func upsertQuestTemplates(
        _ templates: [QuestTemplate],
        family: String? = nil
    ) {
        batchUpsertByFamily(
            templates,
            family: family,
            entityName: "QuestTemplate",
            recordName: { $0.id.recordName },
            familyOf: { $0.family.recordID.recordName },
            apply: { QuestTemplateCache.apply($1, from: $0) }
        )
    }

    func upsertLedgerEntries(
        _ entries: [LedgerEntry],
        family: String? = nil
    ) {
        batchUpsertByFamily(
            entries,
            family: family,
            entityName: "LedgerEntry",
            recordName: { $0.id.recordName },
            familyOf: { $0.family.recordID.recordName },
            apply: { LedgerEntryCache.apply($1, from: $0) }
        )
    }

    func upsertAllowancePeriods(
        _ periods: [AllowancePeriod],
        family: String? = nil
    ) {
        batchUpsertByFamily(
            periods,
            family: family,
            entityName: "AllowancePeriod",
            recordName: { $0.id.recordName },
            familyOf: { $0.family.recordID.recordName },
            apply: { AllowancePeriodCache.apply($1, from: $0) }
        )
    }

    func upsertAchievements(
        _ achievements: [Achievement],
        family: String? = nil
    ) {
        batchUpsertByFamily(
            achievements,
            family: family,
            entityName: "Achievement",
            recordName: { $0.id.recordName },
            familyOf: { $0.family.recordID.recordName },
            apply: { AchievementCache.apply($1, from: $0) }
        )
    }

    func upsertProfileAchievements(
        _ pas: [ProfileAchievement],
        family: String? = nil
    ) {
        batchUpsertByFamily(
            pas,
            family: family,
            entityName: "ProfileAchievement",
            recordName: { $0.id.recordName },
            familyOf: { $0.family.recordID.recordName },
            apply: { ProfileAchievementCache.apply($1, from: $0) }
        )
    }

    func upsertNotificationPreferences(
        _ prefs: [NotificationPreference],
        family: String? = nil
    ) {
        batchUpsertByFamily(
            prefs,
            family: family,
            entityName: "NotificationPreference",
            recordName: { $0.id.recordName },
            familyOf: { $0.family.recordID.recordName },
            apply: { NotificationPreferenceCache.apply($1, from: $0) }
        )
    }

    func upsertGemLedgers(
        _ entries: [GemLedger],
        family: String? = nil
    ) {
        batchUpsertByFamily(
            entries,
            family: family,
            entityName: "GemLedger",
            recordName: { $0.id.recordName },
            familyOf: { $0.family.recordID.recordName },
            apply: { GemLedgerCache.apply($1, from: $0) }
        )
    }
}
