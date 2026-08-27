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

    private func validatedFamilyScope(_ familyRecordName: String?) -> String? {
        guard let familyRecordName, !familyRecordName.isEmpty else {
            logger.warning("Purge skipped: familyRecordName is required, got nil/empty scope")
            return nil
        }
        return familyRecordName
    }

    private func purgeMissing<T: CacheMergeable>(
        _: T.Type,
        validRecordNames: Set<String>,
        familyRecordName: String?
    ) async {
        await purgeMissingWithoutSave(T.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
        saveContext()
    }

    private func purgeMissingWithoutSave<T: CacheMergeable>(
        _: T.Type,
        validRecordNames: Set<String>,
        familyRecordName: String?
    ) async {
        guard !validRecordNames.isEmpty else { return }
        let family: String?
        if T.self == FamilyCache.self {
            family = nil
        } else {
            guard let validated = validatedFamilyScope(familyRecordName) else { return }
            family = validated
        }
        let existing: [T]
        do { existing = try modelContext.fetch(T.fetchDescriptor(familyRecordName: family)) } catch {
            logger.error("Failed to fetch existing \(T.self, privacy: .private) for purgeMissing: \(error, privacy: .private)")
            existing = []
        }
        for cached in existing where !validRecordNames.contains(cached.recordName) {
            modelContext.delete(cached)
        }
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
        familyRecordName: String?
    ) async {
        switch type {
        case .profile:
            await purgeMissingWithoutSave(ProfileCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
        case .family:
            await purgeMissingWithoutSave(FamilyCache.self, validRecordNames: validRecordNames, familyRecordName: nil)
        case .quest:
            await purgeMissingWithoutSave(QuestCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
        case .questTemplate:
            await purgeMissingWithoutSave(QuestTemplateCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
        case .questCompletion:
            await purgeMissingWithoutSave(QuestCompletionCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
        case .ledgerEntry:
            await purgeMissingWithoutSave(LedgerEntryCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
        case .allowancePeriod:
            await purgeMissingWithoutSave(AllowancePeriodCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
        case .achievement:
            await purgeMissingWithoutSave(AchievementCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
        case .profileAchievement:
            await purgeMissingWithoutSave(ProfileAchievementCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
        case .notificationPreference:
            await purgeMissingWithoutSave(NotificationPreferenceCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
        case .gemLedger:
            await purgeMissingWithoutSave(GemLedgerCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
        case .rewardEvent:
            await purgeMissingWithoutSave(RewardEventCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
        case .goal:
            await purgeMissingWithoutSave(GoalCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
        }
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
        switch type {
        case .profile: await deleteRecordByIdentity(ProfileCache.self, identity: identity, expectedActiveZone: expectedActiveZone)
        case .family: await deleteRecordByIdentity(FamilyCache.self, identity: identity, expectedActiveZone: expectedActiveZone)
        case .quest: await deleteRecordByIdentity(QuestCache.self, identity: identity, expectedActiveZone: expectedActiveZone)
        case .questTemplate: await deleteRecordByIdentity(QuestTemplateCache.self, identity: identity, expectedActiveZone: expectedActiveZone)
        case .questCompletion: await deleteRecordByIdentity(QuestCompletionCache.self, identity: identity, expectedActiveZone: expectedActiveZone)
        case .ledgerEntry: await deleteRecordByIdentity(LedgerEntryCache.self, identity: identity, expectedActiveZone: expectedActiveZone)
        case .allowancePeriod: await deleteRecordByIdentity(AllowancePeriodCache.self, identity: identity, expectedActiveZone: expectedActiveZone)
        case .achievement: await deleteRecordByIdentity(AchievementCache.self, identity: identity, expectedActiveZone: expectedActiveZone)
        case .profileAchievement: await deleteRecordByIdentity(ProfileAchievementCache.self, identity: identity, expectedActiveZone: expectedActiveZone)
        case .notificationPreference: await deleteRecordByIdentity(NotificationPreferenceCache.self, identity: identity, expectedActiveZone: expectedActiveZone)
        case .gemLedger: await deleteRecordByIdentity(GemLedgerCache.self, identity: identity, expectedActiveZone: expectedActiveZone)
        case .rewardEvent: await deleteRecordByIdentity(RewardEventCache.self, identity: identity, expectedActiveZone: expectedActiveZone)
        case .goal: await deleteRecordByIdentity(GoalCache.self, identity: identity, expectedActiveZone: expectedActiveZone)
        }
    }

    func deleteByNameAndFamily<T: CacheMergeable & FamilyScopedCache>(
        type _: T.Type,
        recordName: String,
        familyRecordName: String
    ) async {
        let descriptor = FetchDescriptor<T>(predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == familyRecordName })
        do {
            let matches = try modelContext.fetch(descriptor)
            for match in matches {
                modelContext.delete(match)
            }
        } catch {
            logger.warning("Failed to fetch \(T.self, privacy: .public) for invalidation: \(error, privacy: .private)")
        }
        saveContext()
    }

    /// Typed fan-out mirroring performTypedDeletion for callers holding a
    /// runtime record type instead of a concrete cache class. Family rows are
    /// unscoped roots, so they cannot ride the family-scoped generic and are
    /// matched by record name alone.
    func deleteByNameAndFamily(
        _ type: CachedRecordType,
        recordName: String,
        familyRecordName: String
    ) async {
        switch type {
        case .profile:
            await deleteByNameAndFamily(type: ProfileCache.self, recordName: recordName, familyRecordName: familyRecordName)
        case .family:
            do {
                if let match = try modelContext.fetch(FetchDescriptor<FamilyCache>(predicate: #Predicate { $0.recordName == recordName })).first {
                    modelContext.delete(match)
                }
            } catch {
                logger.warning("Failed to fetch FamilyCache for invalidation: \(error, privacy: .private)")
            }
        case .quest:
            await deleteByNameAndFamily(type: QuestCache.self, recordName: recordName, familyRecordName: familyRecordName)
        case .questTemplate:
            await deleteByNameAndFamily(type: QuestTemplateCache.self, recordName: recordName, familyRecordName: familyRecordName)
        case .questCompletion:
            await deleteByNameAndFamily(type: QuestCompletionCache.self, recordName: recordName, familyRecordName: familyRecordName)
        case .ledgerEntry:
            await deleteByNameAndFamily(type: LedgerEntryCache.self, recordName: recordName, familyRecordName: familyRecordName)
        case .allowancePeriod:
            await deleteByNameAndFamily(type: AllowancePeriodCache.self, recordName: recordName, familyRecordName: familyRecordName)
        case .achievement:
            await deleteByNameAndFamily(type: AchievementCache.self, recordName: recordName, familyRecordName: familyRecordName)
        case .profileAchievement:
            await deleteByNameAndFamily(type: ProfileAchievementCache.self, recordName: recordName, familyRecordName: familyRecordName)
        case .notificationPreference:
            await deleteByNameAndFamily(type: NotificationPreferenceCache.self, recordName: recordName, familyRecordName: familyRecordName)
        case .gemLedger:
            await deleteByNameAndFamily(type: GemLedgerCache.self, recordName: recordName, familyRecordName: familyRecordName)
        case .rewardEvent:
            await deleteByNameAndFamily(type: RewardEventCache.self, recordName: recordName, familyRecordName: familyRecordName)
        case .goal:
            await deleteByNameAndFamily(type: GoalCache.self, recordName: recordName, familyRecordName: familyRecordName)
        }
        saveContext()
    }

    /// Sign-out-scale wipe of every cached row. Runs inside the mutation
    /// queue so an in-flight ingestion batch cannot repopulate rows between
    /// the deletes and the save; freshness watermarks are device-local
    /// UserDefaults state and stay with CacheService.
    func clearAllCachedRows() async {
        await SerialMutationQueue.shared.write {
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

    private func deleteRecordByIdentity<T: CacheMergeable>(
        _: T.Type,
        identity: ScopedRecordIdentity,
        expectedActiveZone: CKRecordZone.ID?
    ) async {
        let recordName = identity.recordID.recordName
        let match: T?
        do { match = try modelContext.fetch(T.fetchDescriptor(recordName: recordName)).first } catch {
            logger.error("Failed to fetch \(T.self, privacy: .private) for record deletion (\(recordName, privacy: .private)): \(error, privacy: .private)")
            match = nil
        }
        if let match {
            if let expectedFamily = identity.familyRecordName,
               let scoped = match as? any FamilyScopedCache
            {
                guard scoped.familyRecordName == expectedFamily else {
                    logger.warning(
                        """
                        BackgroundCacheActor deletion aborted for \
                        \(recordName, privacy: .private): expected family \
                        \(expectedFamily, privacy: .private), found \
                        \(scoped.familyRecordName, privacy: .private)
                        """
                    )
                    return
                }
            }
            if let scoped = match as? any FamilyScopedCache, let sourceZone = scoped.sourceZoneName,
               identity.zoneID.zoneName != CKRecordZone.default().zoneID.zoneName, sourceZone != identity.zoneID.zoneName
            {
                let isFamilyMatch: Bool = {
                    guard let expectedFamily = identity.familyRecordName else { return false }
                    return scoped.familyRecordName == expectedFamily
                }()
                let isActiveZone = expectedActiveZone.map { $0 == identity.zoneID } ?? false
                if isFamilyMatch, isActiveZone {
                    logger.info(
                        """
                        BackgroundCacheActor deleting orphan for \
                        \(recordName, privacy: .private): old zone \
                        \(sourceZone, privacy: .private) → active zone \
                        \(identity.zoneID.zoneName, privacy: .private)
                        """
                    )
                } else {
                    logger.warning(
                        """
                        BackgroundCacheActor deletion aborted for \
                        \(recordName, privacy: .private): expected zone \
                        \(identity.zoneID.zoneName, privacy: .private), found \
                        \(sourceZone, privacy: .private)
                        """
                    )
                    return
                }
            }
            modelContext.delete(match)
        }
    }
}
