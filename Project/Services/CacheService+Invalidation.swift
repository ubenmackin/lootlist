//
//  CacheService+Invalidation.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import SwiftData

@MainActor
extension CacheService {
    func deleteAll<T: PersistentModel>(from context: ModelContext?, where predicate: Predicate<T>) {
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

    /// Single invalidation entry — routes all deletes through shared dispatch.
    func invalidate(identity: ScopedRecordIdentity, type: CachedRecordType, expectedActiveZone: CKRecordZone.ID?) async {
        if let backgroundWriter {
            await backgroundWriter.deleteByIdentity(identity, type: type, expectedActiveZone: expectedActiveZone)
        } else {
            invalidateIdentityOnMainActor(identity: identity, type: type, expectedActiveZone: expectedActiveZone)
        }
    }

    /// Main-actor body for in-memory stores where no background writer exists.
    private func invalidateIdentityOnMainActor(
        identity: ScopedRecordIdentity,
        type: CachedRecordType,
        expectedActiveZone: CKRecordZone.ID?
    ) {
        guard let context else { return }
        // WHY single source: typed fan-out lives on CachedRecordType so zone checks never drift.
        type.deleteByIdentity(in: context, identity: identity, expectedActiveZone: expectedActiveZone)
        _ = saveContext()
    }

    func invalidate(recordName: String, family: String, type: CachedRecordType) async {
        if let backgroundWriter {
            await backgroundWriter.deleteByNameAndFamily(type, recordName: recordName, familyRecordName: family)
        } else {
            invalidateByNameAndFamilyOnMainActor(recordName: recordName, family: family, type: type)
        }
    }

    private func invalidateByNameAndFamilyOnMainActor(recordName: String, family: String, type: CachedRecordType) {
        guard let context else { return }
        // WHY single source: typed fan-out lives on CachedRecordType so family scoping never drifts.
        type.deleteByNameAndFamily(in: context, recordName: recordName, familyRecordName: family)
        _ = saveContext()
    }

    func deleteByNameAndFamily(_ type: (some CacheMergeable & FamilyScopedCache).Type, recordName: String, familyRecordName: String) {
        guard let context else { return }
        // WHY single source: scoped deletes share CachedRecordType primitives so indexing never drifts.
        CachedRecordType.deleteScopedByName(type, in: context, recordName: recordName, familyRecordName: familyRecordName)
        saveContext()
    }

    // MARK: - Per-Family Purge

    func purgeFamily(recordName: String) {
        let familyDescriptor = FetchDescriptor<FamilyCache>(predicate: #Predicate { $0.recordName == recordName })
        guard let context else { return }
        do {
            if let family = try context.fetch(familyDescriptor).first {
                context.delete(family)
            }
        } catch {
            logger.error("Failed to fetch family for purge: \(error, privacy: .private)")
            return
        }
        deleteAll(from: context, where: #Predicate<QuestCache> { $0.familyRecordName == recordName })
        deleteAll(from: context, where: #Predicate<QuestTemplateCache> { $0.familyRecordName == recordName })
        deleteAll(from: context, where: #Predicate<QuestCompletionCache> { $0.familyRecordName == recordName })
        deleteAll(from: context, where: #Predicate<LedgerEntryCache> { $0.familyRecordName == recordName })
        deleteAll(from: context, where: #Predicate<AllowancePeriodCache> { $0.familyRecordName == recordName })
        deleteAll(from: context, where: #Predicate<AchievementCache> { $0.familyRecordName == recordName })
        deleteAll(from: context, where: #Predicate<ProfileAchievementCache> { $0.familyRecordName == recordName })
        deleteAll(from: context, where: #Predicate<ProfileCache> { $0.familyRecordName == recordName })
        deleteAll(from: context, where: #Predicate<NotificationPreferenceCache> { $0.familyRecordName == recordName })
        deleteAll(from: context, where: #Predicate<GemLedgerCache> { $0.familyRecordName == recordName })
        deleteAll(from: context, where: #Predicate<RewardEventCache> { $0.familyRecordName == recordName })
        deleteAll(from: context, where: #Predicate<GoalCache> { $0.familyRecordName == recordName })
        invalidateFreshness(forFamilyRecordName: recordName)
        saveContext()
    }

    // MARK: - Bulk Clear

    /// Row deletion rides the single background writer; freshness watermarks
    /// are device-local UserDefaults state and stay on this service.
    func clearAll() async throws {
        if let backgroundWriter {
            await backgroundWriter.clearAllCachedRows()
        } else {
            try clearAllOnMainActor()
        }
        invalidateAllFreshness()
    }

    private func clearAllOnMainActor() throws {
        guard let context else { return }
        try context.delete(model: QuestCache.self)
        try context.delete(model: QuestTemplateCache.self)
        try context.delete(model: ProfileCache.self)
        try context.delete(model: QuestCompletionCache.self)
        try context.delete(model: FamilyCache.self)
        try context.delete(model: LedgerEntryCache.self)
        try context.delete(model: AllowancePeriodCache.self)
        try context.delete(model: AchievementCache.self)
        try context.delete(model: ProfileAchievementCache.self)
        try context.delete(model: NotificationPreferenceCache.self)
        try context.delete(model: GemLedgerCache.self)
        try context.delete(model: RewardEventCache.self)
        try context.delete(model: GoalCache.self)
        do { try trySaveContext() } catch {
            logger.error("Failed to save after clearing cache: \(error, privacy: .private)")
            throw error
        }
        invalidateAllFreshness()
    }
}
