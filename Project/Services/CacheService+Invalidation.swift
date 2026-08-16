//
//  CacheService+Invalidation.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import SwiftData

extension CacheService {
    // MARK: - Generic helper

    /// Fetches the first record matching `descriptor`, deletes it, and saves.
    func invalidate(_ descriptor: FetchDescriptor<some PersistentModel>) {
        guard let context else { return }
        if let object = try? context.fetch(descriptor).first {
            context.delete(object)
            saveContext()
        }
    }

    /// Generic invalidation helper for any model with a recordName.
    func invalidateByRecordName<T: PersistentModel>(
        _: T.Type,
        recordName _: String,
        predicate: Predicate<T>
    ) {
        invalidate(FetchDescriptor<T>(predicate: predicate))
    }

    // MARK: - Per-record invalidation

    private func deleteByNameAndFamily<T: CacheMergeable & FamilyScopedCache>(
        _: T.Type,
        recordName: String,
        familyRecordName: String
    ) {
        guard let context else { return }
        let descriptor = FetchDescriptor<T>(predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == familyRecordName })
        if let matches = try? context.fetch(descriptor) {
            for match in matches {
                context.delete(match)
            }
            saveContext()
        }
    }

    func invalidateQuest(recordName: String, family: String) {
        deleteByNameAndFamily(QuestCache.self, recordName: recordName, familyRecordName: family)
    }

    func invalidateQuest(identity: ScopedRecordIdentity) {
        invalidateRecord(identity: identity, type: .quest)
    }

    func invalidateQuestCompletion(recordName: String, family: String) {
        deleteByNameAndFamily(QuestCompletionCache.self, recordName: recordName, familyRecordName: family)
    }

    func invalidateQuestCompletion(identity: ScopedRecordIdentity) {
        invalidateRecord(identity: identity, type: .questCompletion)
    }

    func invalidateProfile(recordName: String, family: String) {
        deleteByNameAndFamily(ProfileCache.self, recordName: recordName, familyRecordName: family)
    }

    func invalidateProfile(identity: ScopedRecordIdentity) {
        invalidateRecord(identity: identity, type: .profile)
    }

    func invalidateQuestTemplate(recordName: String, family: String) {
        deleteByNameAndFamily(QuestTemplateCache.self, recordName: recordName, familyRecordName: family)
    }

    func invalidateQuestTemplate(identity: ScopedRecordIdentity) {
        invalidateRecord(identity: identity, type: .questTemplate)
    }

    func invalidateLedgerEntry(recordName: String, family: String) {
        deleteByNameAndFamily(LedgerEntryCache.self, recordName: recordName, familyRecordName: family)
    }

    func invalidateLedgerEntry(identity: ScopedRecordIdentity) {
        invalidateRecord(identity: identity, type: .ledgerEntry)
    }

    func invalidateAllowancePeriod(recordName: String, family: String) {
        deleteByNameAndFamily(AllowancePeriodCache.self, recordName: recordName, familyRecordName: family)
    }

    func invalidateAllowancePeriod(identity: ScopedRecordIdentity) {
        invalidateRecord(identity: identity, type: .allowancePeriod)
    }

    func invalidateAchievement(recordName: String, family: String) {
        deleteByNameAndFamily(AchievementCache.self, recordName: recordName, familyRecordName: family)
    }

    func invalidateAchievement(identity: ScopedRecordIdentity) {
        invalidateRecord(identity: identity, type: .achievement)
    }

    func invalidateProfileAchievement(recordName: String, family: String) {
        deleteByNameAndFamily(ProfileAchievementCache.self, recordName: recordName, familyRecordName: family)
    }

    func invalidateProfileAchievement(identity: ScopedRecordIdentity) {
        invalidateRecord(identity: identity, type: .profileAchievement)
    }

    func invalidateFamily(recordName: String) {
        guard let context else { return }
        let descriptor = FetchDescriptor<FamilyCache>(predicate: #Predicate { $0.recordName == recordName })
        if let matches = try? context.fetch(descriptor) {
            for match in matches {
                context.delete(match)
            }
            saveContext()
        }
    }

    func invalidateFamily(identity: ScopedRecordIdentity) {
        invalidateRecord(identity: identity, type: .family)
    }

    func invalidateNotificationPreference(recordName: String, family: String) {
        deleteByNameAndFamily(NotificationPreferenceCache.self, recordName: recordName, familyRecordName: family)
    }

    func invalidateNotificationPreference(identity: ScopedRecordIdentity) {
        invalidateRecord(identity: identity, type: .notificationPreference)
    }

    // MARK: - Per-Family Purge

    /// Deletes the `FamilyCache` matching `recordName` and all child caches
    /// (Quest, QuestTemplate, QuestCompletion, LedgerEntry, AllowancePeriod,
    /// Achievement, ProfileAchievement, Profile, NotificationPreference) whose
    /// `familyRecordName` matches.  Safer than `clearAll()` when removing a
    /// single family from a multi-family cache.
    func purgeFamily(recordName: String) {
        let familyDescriptor = FetchDescriptor<FamilyCache>(
            predicate: #Predicate { $0.recordName == recordName }
        )
        guard let context else { return }
        if let family = try? context.fetch(familyDescriptor).first {
            context.delete(family)
        }

        // Cascade: delete all child caches scoped to this family.
        deleteAll(from: context, where: #Predicate<QuestCache> { $0.familyRecordName == recordName })
        deleteAll(from: context, where: #Predicate<QuestTemplateCache> { $0.familyRecordName == recordName })
        deleteAll(from: context, where: #Predicate<QuestCompletionCache> { $0.familyRecordName == recordName })
        deleteAll(from: context, where: #Predicate<LedgerEntryCache> { $0.familyRecordName == recordName })
        deleteAll(from: context, where: #Predicate<AllowancePeriodCache> { $0.familyRecordName == recordName })
        deleteAll(from: context, where: #Predicate<AchievementCache> { $0.familyRecordName == recordName })
        deleteAll(from: context, where: #Predicate<ProfileAchievementCache> { $0.familyRecordName == recordName })
        deleteAll(from: context, where: #Predicate<ProfileCache> { $0.familyRecordName == recordName })
        deleteAll(from: context, where: #Predicate<NotificationPreferenceCache> { $0.familyRecordName == recordName })

        // The family's rows are gone, so its freshness stamps must go too —
        // otherwise a later partial re-population could look freshly synced.
        invalidateFreshness(forFamilyRecordName: recordName)

        saveContext()
    }

    // MARK: - Bulk Clear

    func clearAll() throws {
        guard let context else { return }
        try? context.delete(model: QuestCache.self)
        try? context.delete(model: QuestTemplateCache.self)
        try? context.delete(model: ProfileCache.self)
        try? context.delete(model: QuestCompletionCache.self)
        try? context.delete(model: FamilyCache.self)
        try? context.delete(model: LedgerEntryCache.self)
        try? context.delete(model: AllowancePeriodCache.self)
        try? context.delete(model: AchievementCache.self)
        try? context.delete(model: ProfileAchievementCache.self)
        try? context.delete(model: NotificationPreferenceCache.self)

        // A swallowed save failure would leave phantom rows persisting past the
        // invalidate-everything wipe — so the save is explicit and rethrown.
        do {
            try trySaveContext()
        } catch {
            logger.error("Failed to save after clearing cache: \(error, privacy: .private)")
            throw error
        }

        // A wiped cache must never serve a stale freshness watermark.
        invalidateAllFreshness()
    }
}
