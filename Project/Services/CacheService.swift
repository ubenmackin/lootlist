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

    /// Cancellable handle for the `ModelContext.didSave` observer.
    /// Stored as `nonisolated(unsafe)` so `deinit` can unregister the
    /// listener without touching main-actor-isolated state — the same
    /// pattern used in `AppLifecycleCoordinator` for `NotificationCenter`
    /// observer tokens, which are not `Sendable` and must not be wrapped
    /// in `@unchecked Sendable` + `Mutex`.
    @ObservationIgnored private nonisolated(unsafe) var didSaveObserver: (any NSObjectProtocol)?

    /// Shorthand for `container.mainContext`.
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

    deinit {
        if let token = didSaveObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Installs the didSave observer: observes every `ModelContext.didSave` and,
    /// when the saved context is a background context of this container, forces
    /// `container.mainContext` to re-evaluate so `@Query` results update
    /// deterministically even when the OS misses automatic cross-context
    /// propagation. The synchronous callback verifies the container pointer
    /// identity (`savedContext.container === container`) while the saved
    /// context is still guaranteed alive on the calling stack, then dispatches
    /// the refresh kick to `@MainActor`.
    private func installDidSaveObserver() {
        guard let container else { return }
        if let token = didSaveObserver {
            NotificationCenter.default.removeObserver(token)
            didSaveObserver = nil
        }
        let token = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: nil,
            queue: nil
        ) { [weak self, weak container] notification in
            guard let container else { return }
            guard let savedContext = notification.object as? ModelContext else { return }
            guard savedContext.container === container else { return }
            guard !Thread.isMainThread else { return }
            Task { @MainActor [weak self] in
                self?.refreshMainContextAfterBackgroundSave()
            }
        }
        didSaveObserver = token
    }

    /// Flushes pending changes so `@Query` re-evaluates after a background save.
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

    /// Marks the cache as fully synced for a family + entity type.
    func markCacheFresh(familyRecordName: String, type: CachedRecordType, at date: Date = Date()) {
        UserDefaults.standard.set(date, forKey: freshnessKey(familyRecordName: familyRecordName, type: type))
    }

    /// Scope-aware overload: stamps freshness for a specific database scope.
    /// A private-only CKSyncEngine pass stamps only the private scope so a
    /// subsequent shared-DB fetch (e.g. hero profiles in the shared database)
    /// does not see `isCacheFresh == true` and return an empty authoritative
    /// result. See `CachedRecordType.fetchScopes` for the scope split and
    /// `CKSyncEngineCoordinator.completeSyncPass` for the gating logic that
    /// requires the relevant scope to have completed before stamping.
    func markCacheFresh(familyRecordName: String, type: CachedRecordType, scope: CKDatabase.Scope, at date: Date = Date()) {
        UserDefaults.standard.set(date, forKey: freshnessKey(familyRecordName: familyRecordName, type: type, scope: scope))
    }

    /// Returns true when a successful sync pass has stamped this
    /// family + entity type. Absent stamps (never synced) and stamps cleared
    /// by `clearAll()` / `purgeFamily(recordName:)` read as stale.
    /// - Note: This legacy scope-agnostic check returns true if *any* scope
    ///   has stamped the type (or the legacy unscoped key exists). Prefer the
    ///   scope-aware `isCacheFresh(familyRecordName:type:scope:)` overload for
    ///   new cache-first gates so a private-only stamp never satisfies a
    ///   shared-DB read.
    func isCacheFresh(familyRecordName: String, type: CachedRecordType) -> Bool {
        // Backward-compatible: legacy unscoped key OR any scoped key counts as fresh.
        // New code should use the scoped overload to avoid cross-scope false positives.
        let legacyKey = freshnessKey(familyRecordName: familyRecordName, type: type)
        if UserDefaults.standard.object(forKey: legacyKey) != nil {
            return true
        }
        for scope in [CKDatabase.Scope.private, .shared]
            where UserDefaults.standard.object(forKey: freshnessKey(familyRecordName: familyRecordName, type: type, scope: scope)) != nil
        {
            return true
        }
        return false
    }

    /// Scope-aware freshness check. Returns true only when the given scope
    /// has been stamped for this family + type. A private-only pass therefore
    /// does not satisfy a shared-scope gate, fixing the hero-list-empty bug
    /// where a subsequent `fetchProfiles` for a shared-DB hero would see an
    /// empty cache as authoritative. Legacy unscoped keys are intentionally
    /// not considered here so per-scope isolation is enforced; callers that
    /// need backward compatibility should use the unscoped overload.
    func isCacheFresh(familyRecordName: String, type: CachedRecordType, scope: CKDatabase.Scope) -> Bool {
        UserDefaults.standard.object(forKey: freshnessKey(familyRecordName: familyRecordName, type: type, scope: scope)) != nil
    }

    /// Removes the freshness stamp for one family + type.
    func invalidateFreshness(familyRecordName: String, type: CachedRecordType) {
        UserDefaults.standard.removeObject(forKey: freshnessKey(familyRecordName: familyRecordName, type: type))
        // Also clear scoped keys so a purge fully invalidates per-scope stamps.
        for scope in [CKDatabase.Scope.private, .shared] {
            UserDefaults.standard.removeObject(forKey: freshnessKey(familyRecordName: familyRecordName, type: type, scope: scope))
        }
    }

    /// Scope-aware removal for one family + type + scope.
    func invalidateFreshness(familyRecordName: String, type: CachedRecordType, scope: CKDatabase.Scope) {
        UserDefaults.standard.removeObject(forKey: freshnessKey(familyRecordName: familyRecordName, type: type, scope: scope))
    }

    /// Removes every freshness stamp.
    func invalidateAllFreshness() {
        let defaults = UserDefaults.standard
        let staleKeys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(Self.freshnessKeyPrefix) }
        for key in staleKeys {
            defaults.removeObject(forKey: key)
        }
    }

    /// Removes every freshness stamp scoped to a single family.
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

    private func freshnessKey(familyRecordName: String, type: CachedRecordType, scope: CKDatabase.Scope) -> String {
        let scopeString = switch scope {
        case .private: "private"
        case .shared: "shared"
        case .public: "public"
        @unknown default: "unknown"
        }
        return "\(Self.freshnessKeyPrefix)\(familyRecordName)_\(scopeString)_\(type.rawValue)"
    }

    // MARK: - Private Helpers

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

    // MARK: - Upserts (single)

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
                // Repair empty-family legacy rows via unscoped fallback.
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
        // isServerSync:true advances lastSyncedXP baseline to prevent cumulative delta drift
        // (Bug A: without advancing, clientDelta = clientXP - lastSyncedXP double-counts).
        // ProfileCache.update handles lastSyncedXP = profile.xp when isServerSync is true.
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
        // Deterministic ledger ID prevents duplicate rows on offline retry.
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

    // MARK: - RewardEvent Atomic Gate

    // Persists a RewardEvent that has been atomically claimed on CloudKit.
    // Call only after `CloudKitService.claimRewardEvent` returns true; the
    // deterministic ID `reward-{completionID}` guarantees at-most-once minting
    // across concurrent devices. Persisting before the claim would leave a
    // phantom local row and a pending sync that later rehydrates `xpCredited`
    // via `BackgroundCacheActor.reconcileRewardEvents`.

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

    /// Removes a phantom RewardEvent left locally when the atomic claim loses.
    /// The loser must not retain the optimistic row or its pending sync, otherwise
    /// a later fetch would hydrate `xpCredited` via `reconcileRewardEvents`.
    func removePhantomRewardEvent(recordName: String, family: String) {
        deleteByNameAndFamily(RewardEventCache.self, recordName: recordName, familyRecordName: family)
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

    // MARK: - Atomic gem credit

    /// Atomically inserts a gem ledger and updates the profile's gem total in a
    /// single ModelContext save.
    ///
    /// Why this exists: the deterministic ledger `recordName` is the CloudKit
    /// idempotency key. A check-then-insert spread across two saves allows two
    /// concurrent credits for the same logical event (e.g. the same loot drop
    /// re-delivered via `CKSyncEngine`) to both observe `nil` and both enqueue,
    /// double-crediting the hero. This method performs the existence check and
    /// the ledger+profile mutation in the same MainActor-isolated transaction
    /// and derives the new balance from the in-memory rows plus the incoming
    /// amount, so a save failure can never leave the ledger persisted while the
    /// profile gems diverges.
    ///
    /// - Returns: `true` when the ledger was inserted and the profile updated;
    ///   `false` when a row with the same deterministic ID already existed or
    ///   the save failed.
    func atomicallyApplyGemCredit(ledger: GemLedger, to profile: Profile) -> Bool {
        guard let context else { return false }
        let familyName = ledger.family.recordID.recordName
        let recordName = ledger.id.recordName

        // Idempotency check inside the same transaction as the insert.
        if fetchGemLedger(recordName: recordName, family: familyName) != nil {
            return false
        }

        // Compute the new balance from existing rows plus the incoming amount
        // rather than re-fetching after insertion — the latter would see a
        // stale context if the subsequent profile save failed.
        let profileRecordName = ledger.profileRecordName
        let predicate = #Predicate<GemLedgerCache> {
            $0.profileRecordName == profileRecordName && $0.familyRecordName == familyName
        }
        let existing: [GemLedgerCache]
        do {
            existing = try context.fetch(FetchDescriptor<GemLedgerCache>(predicate: predicate))
        } catch {
            logger.error("Failed to fetch GemLedgerCache for balance: \(error, privacy: .private)")
            return false
        }
        let newBalance = existing.reduce(0) { $0 + $1.amount } + ledger.amount
        var updatedProfile = profile
        updatedProfile.gems = newBalance

        // Single transaction for both rows — either both persist or neither does,
        // preventing ledger/profile divergence on a partial save failure.
        isBatching = true
        upsertGemLedger(ledger)
        upsertProfile(updatedProfile)
        isBatching = false
        return saveContext()
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

    /// Returns all cached rows keyed by `recordName`, including empty-family
    /// legacy rows so the batch loop can repair them via `update(from:)`.
    private func existingByRecordName<T: CacheMergeable>(
        _: T.Type,
        family: String?
    ) -> [String: T]? {
        guard let context else { return nil }
        do {
            let descriptor = T.fetchDescriptor(familyRecordName: family)
            var existing = try context.fetch(descriptor)

            // Include empty-family legacy rows for repair.
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

    /// Generic batch upsert shared by every `upsert*` batch wrapper.
    ///
    /// When `family` is nil, items are grouped by domain family and handled
    /// per-group. Each item is validated against the explicit family scope.
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
