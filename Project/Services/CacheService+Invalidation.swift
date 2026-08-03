//
//  CacheService+Invalidation.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

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

    func invalidateQuest(recordName: String) {
        invalidateByRecordName(QuestCache.self, recordName: recordName, predicate: #Predicate { $0.recordName == recordName })
    }

    func invalidateQuestCompletion(recordName: String) {
        invalidateByRecordName(QuestCompletionCache.self, recordName: recordName, predicate: #Predicate { $0.recordName == recordName })
    }

    func invalidateProfile(recordName: String) {
        invalidateByRecordName(ProfileCache.self, recordName: recordName, predicate: #Predicate { $0.recordName == recordName })
    }

    func invalidateQuestTemplate(recordName: String) {
        invalidateByRecordName(QuestTemplateCache.self, recordName: recordName, predicate: #Predicate { $0.recordName == recordName })
    }

    func invalidateLedgerEntry(recordName: String) {
        invalidateByRecordName(LedgerEntryCache.self, recordName: recordName, predicate: #Predicate { $0.recordName == recordName })
    }

    func invalidateAllowancePeriod(recordName: String) {
        invalidateByRecordName(AllowancePeriodCache.self, recordName: recordName, predicate: #Predicate { $0.recordName == recordName })
    }

    func invalidateAchievement(recordName: String) {
        invalidateByRecordName(AchievementCache.self, recordName: recordName, predicate: #Predicate { $0.recordName == recordName })
    }

    func invalidateProfileAchievement(recordName: String) {
        invalidateByRecordName(ProfileAchievementCache.self, recordName: recordName, predicate: #Predicate { $0.recordName == recordName })
    }

    func invalidateFamily(recordName: String) {
        invalidateByRecordName(FamilyCache.self, recordName: recordName, predicate: #Predicate { $0.recordName == recordName })
    }

    func invalidateNotificationPreference(recordName: String) {
        invalidateByRecordName(NotificationPreferenceCache.self, recordName: recordName, predicate: #Predicate { $0.recordName == recordName })
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

    func clearAll() {
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
        try? context.save()

        // A wiped cache must never serve a stale freshness watermark (D8).
        invalidateAllFreshness()
    }
}
