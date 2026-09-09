//
//  BackgroundCacheActor+Maintenance.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import os
import SwiftData

extension BackgroundCacheActor {
    // MARK: - Purges (public API preserved as thin wrappers)

    // Deferred purge helpers (purgeMissingWithoutSave / purgeMissingOfType) are called inside
    // commitParticipantReconciliation's single-transaction gate so one saveContext() lands per
    // reconciliation pass. Empty-snapshot abort lives in AppLifecycleCoordinator.fetchFamilySnapshot.

    private func purgeMissing<T: CacheMergeable>(
        _: T.Type,
        validRecordNames: Set<String>,
        familyRecordName: String?
    ) async {
        // WHY standalone guard: transient empty queries must not wipe cache outside settled reconciliation.
        guard !validRecordNames.isEmpty else { return }
        await purgeMissingWithoutSave(T.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
        saveContext()
    }

    private func purgeMissingWithoutSave<T: CacheMergeable>(
        _: T.Type,
        validRecordNames: Set<String>,
        familyRecordName: String?,
        preservedRecordNames: Set<String> = []
    ) async {
        // WHY single source: purge rows share CachedRecordType primitives so pruning never drifts.
        CachedRecordType.purgeRows(T.self, in: modelContext, validRecordNames: validRecordNames, familyRecordName: familyRecordName, preservedRecordNames: preservedRecordNames)
    }

    func purgeMissingQuests(validRecordNames: Set<String>, familyRecordName: String? = nil) async {
        await purgeMissing(QuestCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
    }

    func purgeMissingProfiles(validRecordNames: Set<String>, familyRecordName: String? = nil) async {
        await purgeMissing(ProfileCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
    }

    func purgeMissingQuestCompletions(validRecordNames: Set<String>, familyRecordName: String? = nil) async {
        await purgeMissing(QuestCompletionCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
    }

    func purgeMissingQuestTemplates(validRecordNames: Set<String>, familyRecordName: String? = nil) async {
        await purgeMissing(QuestTemplateCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
    }

    func purgeMissingFamilies(validRecordNames: Set<String>) async {
        await purgeMissing(FamilyCache.self, validRecordNames: validRecordNames, familyRecordName: nil)
    }

    /// Deferred purge dispatch for a runtime-resolved record type, letting
    /// callers keyed on `CachedRecordType` prune without per-type boilerplate.
    func purgeMissingOfType(
        _ type: CachedRecordType,
        validRecordNames: Set<String>,
        familyRecordName: String?,
        preservedRecordNames: Set<String> = []
    ) async {
        // WHY single source: typed fan-out lives on CachedRecordType so pruning never drifts.
        type.purgeMissing(in: modelContext, validRecordNames: validRecordNames, familyRecordName: familyRecordName, preservedRecordNames: preservedRecordNames)
    }

    func purgeFamily(recordName: String) async {
        do {
            if let match = try modelContext.fetch(FamilyCache.fetchDescriptor(recordName: recordName)).first {
                modelContext.delete(match)
            }
        } catch { logger.error("Failed to purge family cache \(recordName, privacy: .private): \(error, privacy: .private)") }
        await purgeFamilyRows(ProfileCache.self, familyRecordName: recordName)
        await purgeFamilyRows(QuestCache.self, familyRecordName: recordName)
        await purgeFamilyRows(QuestTemplateCache.self, familyRecordName: recordName)
        await purgeFamilyRows(QuestCompletionCache.self, familyRecordName: recordName)
        await purgeFamilyRows(LedgerEntryCache.self, familyRecordName: recordName)
        await purgeFamilyRows(AllowancePeriodCache.self, familyRecordName: recordName)
        await purgeFamilyRows(AchievementCache.self, familyRecordName: recordName)
        await purgeFamilyRows(ProfileAchievementCache.self, familyRecordName: recordName)
        await purgeFamilyRows(NotificationPreferenceCache.self, familyRecordName: recordName)
        await purgeFamilyRows(GemLedgerCache.self, familyRecordName: recordName)
        await purgeFamilyRows(RewardEventCache.self, familyRecordName: recordName)
        await purgeFamilyRows(GoalCache.self, familyRecordName: recordName)
        saveContext()
    }

    private func purgeFamilyRows<T: CacheMergeable>(_: T.Type, familyRecordName: String) async {
        let existing: [T]
        do { existing = try modelContext.fetch(T.fetchDescriptor(familyRecordName: familyRecordName)) } catch {
            logger.error("Failed to fetch \(T.self, privacy: .private) for family purge: \(error, privacy: .private)")
            existing = []
        }
        for cached in existing {
            modelContext.delete(cached)
        }
    }

    func backfillTargetCountGlobally() {
        let quests: [QuestCache]
        do { quests = try modelContext.fetch(FetchDescriptor<QuestCache>()) } catch {
            logger.error("Failed to fetch QuestCache for backfill: \(error, privacy: .private)")
            quests = []
        }
        for quest in quests where quest.targetCount <= 0 {
            quest.targetCount = 1
        }
        let templates: [QuestTemplateCache]
        do { templates = try modelContext.fetch(FetchDescriptor<QuestTemplateCache>()) } catch {
            logger.error("Failed to fetch QuestTemplateCache for backfill: \(error, privacy: .private)")
            templates = []
        }
        for template in templates where template.targetCount <= 0 {
            template.targetCount = 1
        }
        saveContext()
        let zeroQuests: [QuestCache]
        do { zeroQuests = try modelContext.fetch(FetchDescriptor<QuestCache>(predicate: #Predicate { $0.targetCount <= 0 })) } catch {
            logger.error("Failed to fetch zero-target QuestCache post-backfill: \(error, privacy: .private)")
            zeroQuests = []
        }
        for quest in zeroQuests {
            logger.warning("QuestCache targetCount stuck at zero post-backfill: \(quest.recordName, privacy: .private)")
        }
        let zeroTemplates: [QuestTemplateCache]
        do { zeroTemplates = try modelContext.fetch(FetchDescriptor<QuestTemplateCache>(predicate: #Predicate { $0.targetCount <= 0 })) } catch {
            logger.error("Failed to fetch zero-target QuestTemplateCache post-backfill: \(error, privacy: .private)")
            zeroTemplates = []
        }
        for template in zeroTemplates {
            logger.warning("QuestTemplateCache targetCount stuck at zero post-backfill: \(template.recordName, privacy: .private)")
        }
        assert(zeroQuests.isEmpty, "QuestCache has zero targetCount post-backfill")
        assert(zeroTemplates.isEmpty, "QuestTemplateCache has zero targetCount post-backfill")
    }

    /// Typed deletion entry point. The caller supplies the active family
    /// zone so this actor never derives sync authority from
    /// device-local defaults itself.
    func deleteByIdentity(_ identity: ScopedRecordIdentity, type: CachedRecordType, expectedActiveZone: CKRecordZone.ID?) async {
        await performTypedDeletion(identity: identity, type: type, expectedActiveZone: expectedActiveZone)
        saveContext()
    }

    /// Shared fan-out so the ingestion path and the domain-write surface run
    /// identical typed deletions behind one save.
    private func performTypedDeletion(identity: ScopedRecordIdentity, type: CachedRecordType, expectedActiveZone: CKRecordZone.ID?) async {
        // WHY single source: typed fan-out lives on CachedRecordType so zone checks never drift.
        type.deleteByIdentity(in: modelContext, identity: identity, expectedActiveZone: expectedActiveZone)
    }

    func deleteByNameAndFamily(
        type: (some CacheMergeable & FamilyScopedCache).Type,
        recordName: String,
        familyRecordName: String
    ) async {
        // WHY single source: scoped deletes share CachedRecordType primitives so indexing never drifts.
        CachedRecordType.deleteScopedByName(type, in: modelContext, recordName: recordName, familyRecordName: familyRecordName)
        saveContext()
    }

    /// Typed fan-out mirroring performTypedDeletion for callers holding a runtime record type instead of a
    /// concrete cache class.
    func deleteByNameAndFamily(
        _ type: CachedRecordType,
        recordName: String,
        familyRecordName: String
    ) async {
        // WHY single source: typed fan-out lives on CachedRecordType so family scoping never drifts.
        type.deleteByNameAndFamily(in: modelContext, recordName: recordName, familyRecordName: familyRecordName)
        saveContext()
    }

    /// Wipes all cached rows inside the mutation queue during sign-out.
    func clearAllCachedRows() async {
        await mutationQueue.write {
            await self.clearAllCachedRowsInTransaction()
        }
    }

    private func clearAllCachedRowsInTransaction() async {
        do {
            try modelContext.delete(model: QuestCache.self)
            try modelContext.delete(model: QuestTemplateCache.self)
            try modelContext.delete(model: ProfileCache.self)
            try modelContext.delete(model: QuestCompletionCache.self)
            try modelContext.delete(model: FamilyCache.self)
            try modelContext.delete(model: LedgerEntryCache.self)
            try modelContext.delete(model: AllowancePeriodCache.self)
            try modelContext.delete(model: AchievementCache.self)
            try modelContext.delete(model: ProfileAchievementCache.self)
            try modelContext.delete(model: NotificationPreferenceCache.self)
            try modelContext.delete(model: GemLedgerCache.self)
            try modelContext.delete(model: RewardEventCache.self)
            try modelContext.delete(model: GoalCache.self)
        } catch {
            logger.error("Failed to delete cached rows: \(error, privacy: .private)")
        }
        guard saveContext() else {
            logger.error("Failed to save after clearing cache")
            return
        }
    }

    // MARK: - Watermark stamping

    // WHY: Single semantic home for freshness stamping keeps TTL and scope rules in one place.
    private func freshnessKey(familyRecordName: String, type: CachedRecordType, scope: CKDatabase.Scope) -> String {
        let scopeString = switch scope {
        case .private: "private"
        case .shared: "shared"
        case .public: "public"
        @unknown default: "unknown"
        }
        return "cache_fresh_\(familyRecordName)_\(scopeString)_\(type.rawValue)"
    }

    // WHY: Scope-aware grouping ensures a private-scope success never over-stamps shared types.
    private func scopedSet(for types: Set<CachedRecordType>, scope: CKDatabase.Scope) -> Set<CachedRecordType> {
        types.filter { $0.fetchScopes.contains(scope) }
    }

    // WHY: Single semantic home groups types per scope and persists only on success so partial failures never mark stale data fresh.
    func stampCacheWatermark(onFamily familyRecordName: String, types: Set<CachedRecordType>, scope: CKDatabase.Scope) async {
        guard !familyRecordName.isEmpty else { return }
        let scoped = scopedSet(for: types, scope: scope)
        guard !scoped.isEmpty else { return }
        // WHY: Stamp-on-success-only — caller gates success; this method only persists the already-validated fresh set.
        let now = Date()
        let defaults = UserDefaults.standard
        for type in scoped {
            defaults.set(now, forKey: freshnessKey(familyRecordName: familyRecordName, type: type, scope: scope))
        }
    }

    // WHY: Convenience overload preserves call-site ergonomics without duplicating grouping logic.
    func stampCacheWatermark(onFamily familyRecordName: String, types: [CachedRecordType], scope: CKDatabase.Scope) async {
        await stampCacheWatermark(onFamily: familyRecordName, types: Set(types), scope: scope)
    }
}
