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
        if let object = try? context.fetch(descriptor).first {
            context.delete(object)
            saveContext()
        }
    }

    // MARK: - Per-record invalidation

    func invalidateQuest(recordName: String) {
        invalidate(FetchDescriptor<QuestCache>(predicate: #Predicate { $0.recordName == recordName }))
    }

    func invalidateQuestCompletion(recordName: String) {
        invalidate(FetchDescriptor<QuestCompletionCache>(predicate: #Predicate { $0.recordName == recordName }))
    }

    func invalidateProfile(recordName: String) {
        invalidate(FetchDescriptor<ProfileCache>(predicate: #Predicate { $0.recordName == recordName }))
    }

    func invalidateQuestTemplate(recordName: String) {
        invalidate(FetchDescriptor<QuestTemplateCache>(predicate: #Predicate { $0.recordName == recordName }))
    }

    func invalidateLedgerEntry(recordName: String) {
        invalidate(FetchDescriptor<LedgerEntryCache>(predicate: #Predicate { $0.recordName == recordName }))
    }

    func invalidateAllowancePeriod(recordName: String) {
        invalidate(FetchDescriptor<AllowancePeriodCache>(predicate: #Predicate { $0.recordName == recordName }))
    }

    func invalidateAchievement(recordName: String) {
        invalidate(FetchDescriptor<AchievementCache>(predicate: #Predicate { $0.recordName == recordName }))
    }

    func invalidateProfileAchievement(recordName: String) {
        invalidate(FetchDescriptor<ProfileAchievementCache>(predicate: #Predicate { $0.recordName == recordName }))
    }

    func invalidateFamily(recordName: String) {
        invalidate(FetchDescriptor<FamilyCache>(predicate: #Predicate { $0.recordName == recordName }))
    }

    func invalidateNotificationPreference(recordName: String) {
        invalidate(FetchDescriptor<NotificationPreferenceCache>(predicate: #Predicate { $0.recordName == recordName }))
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

        saveContext()
    }

    // MARK: - Bulk Clear

    func clearAll() {
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
    }
}
