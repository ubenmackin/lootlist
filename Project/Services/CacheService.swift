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

    #if DEBUG
        @ObservationIgnored
        var ledgerEntryFetchScopes: [String?] = []
    #endif

    @ObservationIgnored private var didSaveToken: NotificationToken?

    var context: ModelContext? {
        container?.mainContext
    }

    let defaults: UserDefaults

    init(inMemory: Bool = false, defaults: UserDefaults = .standard) throws {
        self.defaults = defaults
        let schema = Schema(LootListSchemaV7.models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        do {
            container = try ModelContainer(for: schema, configurations: config)
        } catch {
            logger.error("Failed to create ModelContainer; error category=\(Self.errorCategory(error), privacy: .public). Recreating store...")
            if !inMemory {
                let url = config.url
                do { try FileManager.default.removeItem(at: url) } catch {
                    logger.warning("Failed to remove store file; error category=\(Self.errorCategory(error), privacy: .public)")
                }
                let shmUrl = url.deletingPathExtension().appendingPathExtension("store-shm")
                let walUrl = url.deletingPathExtension().appendingPathExtension("store-wal")
                do { try FileManager.default.removeItem(at: shmUrl) } catch {
                    logger.debug("Failed to remove shm file; error category=\(Self.errorCategory(error), privacy: .public)")
                }
                do { try FileManager.default.removeItem(at: walUrl) } catch {
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

    private func installDidSaveObserver() {
        guard let container else { return }
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
        didSaveToken = NotificationToken(token)
    }

    private func refreshMainContextAfterBackgroundSave() {
        guard let container else { return }
        container.mainContext.processPendingChanges()
    }

    func withBatch(_ work: () -> Void) {
        isBatching = true
        defer {
            isBatching = false
            saveContext()
        }
        work()
    }

    func trySaveContext() throws {
        guard let context else { return }
        try context.save()
    }

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

    /// Legacy stamp (no scope) — prefer scope-aware overload; scope-isolated so private-only pass never satisfies shared reads (§2, CachedRecordType.fetchScopes,
    /// completeSyncPass).
    func markCacheFresh(familyRecordName: String, type: CachedRecordType, at date: Date = Date()) {
        defaults.set(date, forKey: freshnessKey(familyRecordName: familyRecordName, type: type))
    }

    /// Stamps freshness for `type` in `scope`. Scope-isolated: private-only sync must not satisfy shared-DB reads (§2, CachedRecordType.fetchScopes, completeSyncPass gating).
    func markCacheFresh(familyRecordName: String, type: CachedRecordType, scope: CKDatabase.Scope, at date: Date = Date()) {
        defaults.set(date, forKey: freshnessKey(familyRecordName: familyRecordName, type: type, scope: scope))
    }

    /// Legacy check (legacy OR any scope). Prefer scope-aware overload — scope-isolated reads must use `isCacheFresh(scope:)` so private-only never satisfies shared (§2,
    /// fetchScopes).
    func isCacheFresh(familyRecordName: String, type: CachedRecordType) -> Bool {
        let legacyKey = freshnessKey(familyRecordName: familyRecordName, type: type)
        if defaults.object(forKey: legacyKey) != nil {
            return true
        }
        for scope in [CKDatabase.Scope.private, .shared]
            where defaults.object(forKey: freshnessKey(familyRecordName: familyRecordName, type: type, scope: scope)) != nil
        {
            return true
        }
        return false
    }

    /// Returns true only if `scope` was stamped. Scope-isolated: private-only pass must not satisfy shared-DB reads (§2, CachedRecordType.fetchScopes, completeSyncPass).
    func isCacheFresh(familyRecordName: String, type: CachedRecordType, scope: CKDatabase.Scope) -> Bool {
        defaults.object(forKey: freshnessKey(familyRecordName: familyRecordName, type: type, scope: scope)) != nil
    }

    /// Invalidates legacy + both scopes. Scope-isolated — clears private/shared watermarks together (§2, CachedRecordType.fetchScopes).
    func invalidateFreshness(familyRecordName: String, type: CachedRecordType) {
        defaults.removeObject(forKey: freshnessKey(familyRecordName: familyRecordName, type: type))
        for scope in [CKDatabase.Scope.private, .shared] {
            defaults.removeObject(forKey: freshnessKey(familyRecordName: familyRecordName, type: type, scope: scope))
        }
    }

    /// Invalidates freshness for `type` in `scope` only. Scope-isolated — removing private must not affect shared (§2, CachedRecordType.fetchScopes).
    func invalidateFreshness(familyRecordName: String, type: CachedRecordType, scope: CKDatabase.Scope) {
        defaults.removeObject(forKey: freshnessKey(familyRecordName: familyRecordName, type: type, scope: scope))
    }

    func invalidateAllFreshness() {
        let staleKeys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(Self.freshnessKeyPrefix) }
        for key in staleKeys {
            defaults.removeObject(forKey: key)
        }
    }

    func invalidateFreshness(forFamilyRecordName familyRecordName: String) {
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
            \(recordName, privacy: .private): requested=\
            \(requestedFamily, privacy: .private) actual=\
            \(actualFamily, privacy: .private)
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
            if let existing = try context.fetch(descriptor).first(where: {
                $0.recordName == recordName
            }) {
                if let familyRecordName, !existing.familyRecordName.isEmpty,
                   existing.familyRecordName != familyRecordName
                {
                    logger.warning(
                        """
                        Scope mismatch ignoring upsert for \(entityName, privacy: .public) \
                        \(recordName, privacy: .private): existing=\
                        \(existing.familyRecordName, privacy: .private) expected=\
                        \(familyRecordName, privacy: .private)
                        """
                    )
                    return
                }
                T.apply(existing, from: domain, isServerSync: isServerSync)
            } else if let familyRecordName, !familyRecordName.isEmpty {
                let unscopedDescriptor = T.fetchDescriptor(familyRecordName: nil)
                if let legacyRow = try context.fetch(unscopedDescriptor).first(where: { $0.recordName == recordName }),
                   legacyRow.familyRecordName.isEmpty
                {
                    T.apply(legacyRow, from: domain, isServerSync: isServerSync)
                    logger.info("Repaired empty-family legacy \(entityName, privacy: .public) \(recordName, privacy: .private) → family \(familyRecordName, privacy: .private)")
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
        applyUpsert(
            quest,
            type: QuestCache.self,
            recordName: quest.id.recordName,
            familyRecordName: familyRecordName ?? quest.family.recordID.recordName,
            isServerSync: isServerSync,
            entityName: "Quest"
        )
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
        applyUpsert(
            profile,
            type: ProfileCache.self,
            recordName: profile.id.recordName,
            familyRecordName: familyRecordName ?? profile.family.recordID.recordName,
            isServerSync: isServerSync,
            entityName: "Profile"
        )
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
        applyUpsert(
            completion,
            type: QuestCompletionCache.self,
            recordName: completion.id.recordName,
            familyRecordName: familyRecordName ?? completion.family.recordID.recordName,
            isServerSync: isServerSync,
            entityName: "QuestCompletion"
        )
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
        applyUpsert(
            template,
            type: QuestTemplateCache.self,
            recordName: template.id.recordName,
            familyRecordName: familyRecordName ?? template.family.recordID.recordName,
            isServerSync: isServerSync,
            entityName: "QuestTemplate"
        )
    }

    func upsertFamily(_ family: Family, isServerSync: Bool = false) {
        applyUpsert(family, type: FamilyCache.self, recordName: family.id.recordName, familyRecordName: nil, isServerSync: isServerSync, entityName: "Family")
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
        applyUpsert(
            entry,
            type: LedgerEntryCache.self,
            recordName: entry.id.recordName,
            familyRecordName: familyRecordName ?? entry.family.recordID.recordName,
            isServerSync: isServerSync,
            entityName: "LedgerEntry"
        )
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
        applyUpsert(
            period,
            type: AllowancePeriodCache.self,
            recordName: period.id.recordName,
            familyRecordName: familyRecordName ?? period.family.recordID.recordName,
            isServerSync: isServerSync,
            entityName: "AllowancePeriod"
        )
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
        applyUpsert(
            achievement,
            type: AchievementCache.self,
            recordName: achievement.id.recordName,
            familyRecordName: familyRecordName ?? achievement.family.recordID.recordName,
            isServerSync: isServerSync,
            entityName: "Achievement"
        )
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
        applyUpsert(
            pref,
            type: NotificationPreferenceCache.self,
            recordName: pref.id.recordName,
            familyRecordName: familyRecordName ?? pref.family.recordID.recordName,
            isServerSync: isServerSync,
            entityName: "NotificationPreference"
        )
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
        applyUpsert(
            entry,
            type: GemLedgerCache.self,
            recordName: entry.id.recordName,
            familyRecordName: familyRecordName ?? entry.family.recordID.recordName,
            isServerSync: isServerSync,
            entityName: "GemLedger"
        )
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
        applyUpsert(
            event,
            type: RewardEventCache.self,
            recordName: event.id.recordName,
            familyRecordName: familyRecordName ?? event.family.recordID.recordName,
            isServerSync: isServerSync,
            entityName: "RewardEvent"
        )
    }

    func removePhantomRewardEvent(recordName: String, family: String) {
        deleteByNameAndFamily(RewardEventCache.self, recordName: recordName, familyRecordName: family)
    }

    func applyGemDebit(profile: Profile, ledger: GemLedger) {
        withBatch {
            upsertProfile(profile, isServerSync: true)
            upsertGemLedger(ledger, isServerSync: true)
        }
    }

    func atomicallyApplyGemCredit(ledger: GemLedger, to profile: Profile) -> Bool {
        guard let context else { return false }
        guard sharedGemCreditPrepare(context: context, ledger: ledger, profile: profile) else {
            return false
        }
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
        applyUpsert(
            pa,
            type: ProfileAchievementCache.self,
            recordName: pa.id.recordName,
            familyRecordName: familyRecordName ?? pa.family.recordID.recordName,
            isServerSync: isServerSync,
            entityName: "ProfileAchievement"
        )
    }

    // MARK: - Batch Upserts

    private func existingByRecordName<T: CacheMergeable>(_: T.Type, family: String?) -> [String: T]? {
        guard let context else { return nil }
        do {
            let descriptor = T.fetchDescriptor(familyRecordName: family)
            var existing = try context.fetch(descriptor)
            if let family, !family.isEmpty {
                let unscoped = T.fetchDescriptor(familyRecordName: nil)
                let allRows = try context.fetch(unscoped)
                for row in allRows where row.familyRecordName.isEmpty {
                    existing.append(row)
                }
            }
            return Dictionary(existing.map { ($0.recordName, $0) }, uniquingKeysWith: { current, _ in current })
        } catch {
            logger.error("Failed to fetch \(String(describing: T.self), privacy: .public) by record name: \(error, privacy: .private)")
            return nil
        }
    }

    /// Single private generic — all batch wrappers route through here.
    private func batchUpsert<T: CacheMergeable>(_: T.Type, items: [T.DomainModel], familyRecordName: String?) {
        if let familyRecordName {
            guard let context else { return }
            guard let existingMap = existingByRecordName(T.self, family: familyRecordName) else { return }
            for item in items {
                let name = item.id.recordName
                let itemFamily = T(from: item).familyRecordName
                if !itemFamily.isEmpty, itemFamily != familyRecordName {
                    logFamilyMismatch(
                        action: "Explicit family mismatch ignoring batch upsert for",
                        entityName: String(describing: T.self),
                        recordName: name,
                        requestedFamily: familyRecordName,
                        actualFamily: itemFamily
                    )
                    continue
                }
                if let cached = existingMap[name] {
                    guard cached.familyRecordName.isEmpty
                        || cached.familyRecordName == familyRecordName
                    else {
                        logger.warning(
                            """
                            Scope mismatch ignoring batch upsert for \
                            \(String(describing: T.self), privacy: .public) \
                            \(name, privacy: .private): existing=\
                            \(cached.familyRecordName, privacy: .private) expected=\
                            \(familyRecordName, privacy: .private)
                            """
                        )
                        continue
                    }
                    T.apply(cached, from: item)
                } else {
                    context.insert(T(from: item))
                }
            }
            saveContext()
            return
        }
        // Nil scope — group by family to keep each family's save isolated.
        if T.self == FamilyCache.self {
            guard let context else { return }
            guard let existingMap = existingByRecordName(T.self, family: nil) else { return }
            for item in items {
                let name = item.id.recordName
                if let cached = existingMap[name] {
                    T.apply(cached, from: item)
                } else {
                    context.insert(T(from: item))
                }
            }
            saveContext()
            return
        }
        let grouped = Dictionary(grouping: items) { T(from: $0).familyRecordName }
        for (family, group) in grouped {
            batchUpsert(T.self, items: group, familyRecordName: family.isEmpty ? nil : family)
        }
    }

    private func purgeMissing<T: CacheMergeable>(_: T.Type, validRecordNames: Set<String>, familyRecordName: String?) {
        guard !validRecordNames.isEmpty else { return }
        guard let context else { return }
        let family: String? = (T.self == FamilyCache.self) ? nil : familyRecordName
        if T.self != FamilyCache.self, family == nil || family?.isEmpty == true {
            return
        }
        do {
            let existing = try context.fetch(T.fetchDescriptor(familyRecordName: family))
            for cached in existing where !validRecordNames.contains(cached.recordName) {
                context.delete(cached)
            }
            saveContext()
        } catch {
            logger.error("Failed to fetch \(T.self, privacy: .private) for purgeMissing: \(error, privacy: .private)")
        }
    }

    func upsertQuests(_ quests: [Quest], family: String? = nil) {
        batchUpsert(QuestCache.self, items: quests, familyRecordName: family)
    }

    func upsertProfiles(_ profiles: [Profile], family: String? = nil) {
        batchUpsert(ProfileCache.self, items: profiles, familyRecordName: family)
    }

    func upsertQuestCompletions(_ completions: [QuestCompletion], family: String? = nil) {
        batchUpsert(QuestCompletionCache.self, items: completions, familyRecordName: family)
    }

    func upsertQuestTemplates(_ templates: [QuestTemplate], family: String? = nil) {
        batchUpsert(QuestTemplateCache.self, items: templates, familyRecordName: family)
    }

    func upsertLedgerEntries(_ entries: [LedgerEntry], family: String? = nil) {
        batchUpsert(LedgerEntryCache.self, items: entries, familyRecordName: family)
    }

    func upsertAllowancePeriods(_ periods: [AllowancePeriod], family: String? = nil) {
        batchUpsert(AllowancePeriodCache.self, items: periods, familyRecordName: family)
    }

    func upsertAchievements(_ achievements: [Achievement], family: String? = nil) {
        batchUpsert(AchievementCache.self, items: achievements, familyRecordName: family)
    }

    func upsertProfileAchievements(_ pas: [ProfileAchievement], family: String? = nil) {
        batchUpsert(ProfileAchievementCache.self, items: pas, familyRecordName: family)
    }

    func upsertNotificationPreferences(_ prefs: [NotificationPreference], family: String? = nil) {
        batchUpsert(
            NotificationPreferenceCache.self,
            items: prefs,
            familyRecordName: family
        )
    }

    func upsertGemLedgers(_ entries: [GemLedger], family: String? = nil) {
        batchUpsert(GemLedgerCache.self, items: entries, familyRecordName: family)
    }

    func upsertRewardEvents(_ events: [RewardEvent], family: String? = nil) {
        batchUpsert(RewardEventCache.self, items: events, familyRecordName: family)
    }
}

/// Shared gem-credit mutation — single transaction keeps ledger and profile
/// in sync and guarantees idempotency via deterministic ledger recordName.
func sharedGemCreditPrepare(
    context: ModelContext,
    ledger: GemLedger,
    profile: Profile
) -> Bool {
    let familyName = ledger.family.recordID.recordName
    let recordName = ledger.id.recordName
    let profileRecordName = ledger.profileRecordName
    do {
        let dup = try context.fetch(FetchDescriptor<GemLedgerCache>(predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == familyName }))
        if dup.first != nil {
            return false
        }
    } catch { return false }
    let existingRows: [GemLedgerCache]
    do {
        existingRows = try context.fetch(FetchDescriptor<GemLedgerCache>(predicate: #Predicate { $0.profileRecordName == profileRecordName && $0.familyRecordName == familyName }))
    } catch { return false }
    let newBalance = existingRows.reduce(0) { $0 + $1.amount } + ledger.amount
    var updated = profile
    updated.gems = newBalance
    context.insert(GemLedgerCache(from: ledger))
    do {
        let pd = FetchDescriptor<ProfileCache>(predicate: #Predicate { $0.recordName == profileRecordName && $0.familyRecordName == familyName })
        if let existing = try context.fetch(pd).first {
            existing.update(from: updated, isServerSync: true)
        } else {
            context.insert(ProfileCache(from: updated))
        }
    } catch { return false }
    return true
}
