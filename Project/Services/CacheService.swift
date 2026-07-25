//
//  CacheService.swift
//  LootList
//
//

import CloudKit
import Foundation
import SwiftData

/// Local SwiftData cache layered in front of CloudKit.
///
/// **Read path:** check cache first → return immediately if present → refresh
/// from CloudKit in the background and update both cache + published state.
///
/// **Write path:** every successful CloudKit save/query also upserts into
/// SwiftData so subsequent reads are instant.
@MainActor
@Observable
final class CacheService {
    let container: ModelContainer

    init(inMemory: Bool = false) throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        container = try ModelContainer(
            for: QuestCache.self,
            QuestTemplateCache.self,
            ProfileCache.self,
            QuestCompletionCache.self,
            FamilyCache.self,
            LedgerEntryCache.self,
            AllowancePeriodCache.self,
            AchievementCache.self,
            ProfileAchievementCache.self,
            NotificationPreferenceCache.self,
            configurations: config
        )
    }

    // MARK: - Upserts (single)

    func upsertQuest(_ quest: Quest, family _: String? = nil) {
        let context = container.mainContext
        let name = quest.id.recordName
        let descriptor = FetchDescriptor<QuestCache>(
            predicate: #Predicate { $0.recordName == name }
        )
        if let existing = try? context.fetch(descriptor).first {
            existing.familyRecordName = quest.family.recordID.recordName
            existing.assigneeRecordName = quest.assignee.recordID.recordName
            existing.templateRecordName = quest.template.recordID.recordName
            existing.weekOf = quest.weekOf
            existing.questName = quest.displayName
            existing.isActive = quest.active
            existing.goldReward = quest.goldReward
            existing.xpReward = quest.xpReward
            existing.rarity = quest.rarity.rawValue
            existing.scheduleType = quest.scheduleType.rawValue
            existing.isAllOrNothing = quest.isAllOrNothing
            existing.approvalMode = quest.approvalMode.rawValue
            existing.descriptionText = quest.descriptionText
            existing.createdByRecordName = quest.createdBy.recordID.recordName
        } else {
            context.insert(QuestCache(from: quest))
        }
        try? context.save()
    }

    func upsertProfile(_ profile: Profile, family _: String? = nil) {
        let context = container.mainContext
        let name = profile.id.recordName
        let descriptor = FetchDescriptor<ProfileCache>(
            predicate: #Predicate { $0.recordName == name }
        )
        if let existing = try? context.fetch(descriptor).first {
            existing.familyRecordName = profile.family.recordID.recordName
            existing.displayName = profile.displayName
            existing.role = profile.role.rawValue
            existing.xpTotal = profile.xp
            existing.avatarName = profile.avatarPresetID
            existing.isActive = profile.isActive
            existing.level = profile.level
            existing.iCloudUserRecordName = profile.iCloudUserID.recordName
            existing.avatarClass = profile.avatarClass?.rawValue
            existing.payoutPolicy = profile.payoutPolicy.rawValue
        } else {
            context.insert(ProfileCache(from: profile))
        }
        try? context.save()
    }

    func upsertQuestCompletion(_ completion: QuestCompletion, family _: String? = nil) {
        let context = container.mainContext
        let name = completion.id.recordName
        let descriptor = FetchDescriptor<QuestCompletionCache>(
            predicate: #Predicate { $0.recordName == name }
        )
        if let existing = try? context.fetch(descriptor).first {
            existing.questRecordName = completion.quest.recordID.recordName
            existing.familyRecordName = completion.family.recordID.recordName
            existing.completerRecordName = completion.completedBy.recordID.recordName
            existing.completedDate = completion.completedDate
            existing.weekOf = completion.weekOf
            existing.verificationStatus = completion.verificationStatus.rawValue
            existing.verifiedByRecordName = completion.verifiedBy?.recordID.recordName
            existing.verifiedDate = completion.verifiedDate
        } else {
            context.insert(QuestCompletionCache(from: completion))
        }
        try? context.save()
    }

    func upsertQuestTemplate(_ template: QuestTemplate, family _: String? = nil) {
        let context = container.mainContext
        let name = template.id.recordName
        let descriptor = FetchDescriptor<QuestTemplateCache>(
            predicate: #Predicate { $0.recordName == name }
        )
        if let existing = try? context.fetch(descriptor).first {
            existing.familyRecordName = template.family.recordID.recordName
            existing.name = template.name
            existing.isActive = template.isActive
            existing.goldReward = template.defaultGold
            existing.xpReward = template.xpReward
            existing.rarity = template.rarity.rawValue
            existing.specificDays = template.specificDays.isEmpty ? nil : template.specificDays
            existing.templateDescription = template.description
            existing.scheduleType = template.scheduleType.rawValue
            existing.isAllOrNothing = template.isAllOrNothing
            existing.approvalMode = template.approvalMode.rawValue
            existing.createdByRecordName = template.createdBy.recordID.recordName
        } else {
            context.insert(QuestTemplateCache(from: template))
        }
        try? context.save()
    }

    func upsertFamily(_ family: Family) {
        let context = container.mainContext
        let name = family.id.recordName
        let descriptor = FetchDescriptor<FamilyCache>(
            predicate: #Predicate { $0.recordName == name }
        )
        if let existing = try? context.fetch(descriptor).first {
            existing.name = family.name
            existing.createdByRecordName = family.createdBy.recordName
            existing.createdAt = family.createdAt
            existing.payoutPolicy = family.payoutPolicy.rawValue
        } else {
            context.insert(FamilyCache(from: family))
        }
        try? context.save()
    }

    func upsertLedgerEntry(_ entry: LedgerEntry) {
        let context = container.mainContext
        let name = entry.id.recordName
        let descriptor = FetchDescriptor<LedgerEntryCache>(
            predicate: #Predicate { $0.recordName == name }
        )
        if let existing = try? context.fetch(descriptor).first {
            existing.profileRecordName = entry.profile.recordID.recordName
            existing.familyRecordName = entry.family.recordID.recordName
            existing.amount = entry.amount
            existing.entryDescription = entry.description
            existing.date = entry.date
            existing.source = entry.source
        } else {
            context.insert(LedgerEntryCache(from: entry))
        }
        try? context.save()
    }

    func upsertAllowancePeriod(_ period: AllowancePeriod) {
        let context = container.mainContext
        let name = period.id.recordName
        let descriptor = FetchDescriptor<AllowancePeriodCache>(
            predicate: #Predicate { $0.recordName == name }
        )
        if let existing = try? context.fetch(descriptor).first {
            existing.profileRecordName = period.profile.recordID.recordName
            existing.familyRecordName = period.family.recordID.recordName
            existing.weekOf = period.weekOf
            existing.status = period.status.rawValue
            existing.totalEarned = period.totalEarned
            existing.questsCompleted = period.questsCompleted
            existing.questsTotal = period.questsTotal
            existing.paidDate = period.paidDate
            existing.paidAmount = period.paidAmount
        } else {
            context.insert(AllowancePeriodCache(from: period))
        }
        try? context.save()
    }

    func upsertAchievement(_ achievement: Achievement) {
        let context = container.mainContext
        let name = achievement.id.recordName
        let descriptor = FetchDescriptor<AchievementCache>(
            predicate: #Predicate { $0.recordName == name }
        )
        if let existing = try? context.fetch(descriptor).first {
            existing.familyRecordName = achievement.family.recordID.recordName
            existing.name = achievement.name
            existing.achievementDescription = achievement.description
            existing.iconSystemName = achievement.iconSystemName
            existing.category = achievement.category.rawValue
            existing.requirementType = achievement.requirementType.rawValue
            existing.requirementValue = achievement.requirementValue
        } else {
            context.insert(AchievementCache(from: achievement))
        }
        try? context.save()
    }

    func upsertNotificationPreference(_ pref: NotificationPreference) {
        let context = container.mainContext
        let name = pref.id.recordName
        let descriptor = FetchDescriptor<NotificationPreferenceCache>(
            predicate: #Predicate { $0.recordName == name }
        )
        if let existing = try? context.fetch(descriptor).first {
            existing.profileRecordName = pref.profile.recordID.recordName
            existing.familyRecordName = pref.family.recordID.recordName
            existing.eventType = pref.eventType.rawValue
            existing.enabled = pref.enabled
            existing.pushEnabled = pref.pushEnabled
        } else {
            context.insert(NotificationPreferenceCache(from: pref))
        }
        try? context.save()
    }

    func upsertProfileAchievement(_ pa: ProfileAchievement) {
        let context = container.mainContext
        let name = pa.id.recordName
        let descriptor = FetchDescriptor<ProfileAchievementCache>(
            predicate: #Predicate { $0.recordName == name }
        )
        if let existing = try? context.fetch(descriptor).first {
            existing.achievementRecordName = pa.achievement.recordID.recordName
            existing.profileRecordName = pa.profile.recordID.recordName
            existing.familyRecordName = pa.family.recordID.recordName
            existing.earnedDate = pa.earnedDate
        } else {
            context.insert(ProfileAchievementCache(from: pa))
        }
        try? context.save()
    }

    // MARK: - Batch Upserts

    func upsertQuests(_ quests: [Quest], family _: String? = nil) {
        let context = container.mainContext
        let existing = (try? context.fetch(FetchDescriptor<QuestCache>())) ?? []
        let existingMap = Dictionary(existing.map { ($0.recordName, $0) }, uniquingKeysWith: { first, _ in first })

        for quest in quests {
            let name = quest.id.recordName
            if let cached = existingMap[name] {
                cached.familyRecordName = quest.family.recordID.recordName
                cached.assigneeRecordName = quest.assignee.recordID.recordName
                cached.templateRecordName = quest.template.recordID.recordName
                cached.weekOf = quest.weekOf
                cached.questName = quest.displayName
                cached.isActive = quest.active
                cached.goldReward = quest.goldReward
                cached.xpReward = quest.xpReward
                cached.rarity = quest.rarity.rawValue
                cached.scheduleType = quest.scheduleType.rawValue
                cached.isAllOrNothing = quest.isAllOrNothing
                cached.approvalMode = quest.approvalMode.rawValue
                cached.descriptionText = quest.descriptionText
                cached.createdByRecordName = quest.createdBy.recordID.recordName
            } else {
                context.insert(QuestCache(from: quest))
            }
        }
        try? context.save()
    }

    func upsertProfiles(_ profiles: [Profile], family _: String? = nil) {
        let context = container.mainContext
        let existing = (try? context.fetch(FetchDescriptor<ProfileCache>())) ?? []
        let existingMap = Dictionary(existing.map { ($0.recordName, $0) }, uniquingKeysWith: { first, _ in first })

        for profile in profiles {
            let name = profile.id.recordName
            if let cached = existingMap[name] {
                cached.familyRecordName = profile.family.recordID.recordName
                cached.displayName = profile.displayName
                cached.role = profile.role.rawValue
                cached.xpTotal = profile.xp
                cached.avatarName = profile.avatarPresetID
                cached.isActive = profile.isActive
                cached.level = profile.level
                cached.iCloudUserRecordName = profile.iCloudUserID.recordName
                cached.avatarClass = profile.avatarClass?.rawValue
                cached.payoutPolicy = profile.payoutPolicy.rawValue
            } else {
                context.insert(ProfileCache(from: profile))
            }
        }
        try? context.save()
    }

    func upsertQuestCompletions(_ completions: [QuestCompletion], family _: String? = nil) {
        let context = container.mainContext
        let existing = (try? context.fetch(FetchDescriptor<QuestCompletionCache>())) ?? []
        let existingMap = Dictionary(existing.map { ($0.recordName, $0) }, uniquingKeysWith: { first, _ in first })

        for completion in completions {
            let name = completion.id.recordName
            if let cached = existingMap[name] {
                cached.questRecordName = completion.quest.recordID.recordName
                cached.familyRecordName = completion.family.recordID.recordName
                cached.completerRecordName = completion.completedBy.recordID.recordName
                cached.completedDate = completion.completedDate
                cached.weekOf = completion.weekOf
                cached.verificationStatus = completion.verificationStatus.rawValue
                cached.verifiedByRecordName = completion.verifiedBy?.recordID.recordName
                cached.verifiedDate = completion.verifiedDate
            } else {
                context.insert(QuestCompletionCache(from: completion))
            }
        }
        try? context.save()
    }

    func upsertQuestTemplates(_ templates: [QuestTemplate], family _: String? = nil) {
        let context = container.mainContext
        let existing = (try? context.fetch(FetchDescriptor<QuestTemplateCache>())) ?? []
        let existingMap = Dictionary(existing.map { ($0.recordName, $0) }, uniquingKeysWith: { first, _ in first })

        for template in templates {
            let name = template.id.recordName
            if let cached = existingMap[name] {
                cached.familyRecordName = template.family.recordID.recordName
                cached.name = template.name
                cached.isActive = template.isActive
                cached.goldReward = template.defaultGold
                cached.xpReward = template.xpReward
                cached.rarity = template.rarity.rawValue
                cached.specificDays = template.specificDays.isEmpty ? nil : template.specificDays
                cached.templateDescription = template.description
                cached.scheduleType = template.scheduleType.rawValue
                cached.isAllOrNothing = template.isAllOrNothing
                cached.approvalMode = template.approvalMode.rawValue
                cached.createdByRecordName = template.createdBy.recordID.recordName
            } else {
                context.insert(QuestTemplateCache(from: template))
            }
        }
        try? context.save()
    }

    func upsertLedgerEntries(_ entries: [LedgerEntry]) {
        let context = container.mainContext
        let existing = (try? context.fetch(FetchDescriptor<LedgerEntryCache>())) ?? []
        let existingMap = Dictionary(existing.map { ($0.recordName, $0) }, uniquingKeysWith: { first, _ in first })

        for entry in entries {
            let name = entry.id.recordName
            if let cached = existingMap[name] {
                cached.profileRecordName = entry.profile.recordID.recordName
                cached.familyRecordName = entry.family.recordID.recordName
                cached.amount = entry.amount
                cached.entryDescription = entry.description
                cached.date = entry.date
                cached.source = entry.source
            } else {
                context.insert(LedgerEntryCache(from: entry))
            }
        }
        try? context.save()
    }

    func upsertAllowancePeriods(_ periods: [AllowancePeriod]) {
        let context = container.mainContext
        let existing = (try? context.fetch(FetchDescriptor<AllowancePeriodCache>())) ?? []
        let existingMap = Dictionary(existing.map { ($0.recordName, $0) }, uniquingKeysWith: { first, _ in first })

        for period in periods {
            let name = period.id.recordName
            if let cached = existingMap[name] {
                cached.profileRecordName = period.profile.recordID.recordName
                cached.familyRecordName = period.family.recordID.recordName
                cached.weekOf = period.weekOf
                cached.status = period.status.rawValue
                cached.totalEarned = period.totalEarned
                cached.questsCompleted = period.questsCompleted
                cached.questsTotal = period.questsTotal
                cached.paidDate = period.paidDate
                cached.paidAmount = period.paidAmount
            } else {
                context.insert(AllowancePeriodCache(from: period))
            }
        }
        try? context.save()
    }

    func upsertAchievements(_ achievements: [Achievement]) {
        let context = container.mainContext
        let existing = (try? context.fetch(FetchDescriptor<AchievementCache>())) ?? []
        let existingMap = Dictionary(existing.map { ($0.recordName, $0) }, uniquingKeysWith: { first, _ in first })

        for achievement in achievements {
            let name = achievement.id.recordName
            if let cached = existingMap[name] {
                cached.familyRecordName = achievement.family.recordID.recordName
                cached.name = achievement.name
                cached.achievementDescription = achievement.description
                cached.iconSystemName = achievement.iconSystemName
                cached.category = achievement.category.rawValue
                cached.requirementType = achievement.requirementType.rawValue
                cached.requirementValue = achievement.requirementValue
            } else {
                context.insert(AchievementCache(from: achievement))
            }
        }
        try? context.save()
    }

    func upsertProfileAchievements(_ pas: [ProfileAchievement]) {
        let context = container.mainContext
        let existing = (try? context.fetch(FetchDescriptor<ProfileAchievementCache>())) ?? []
        let existingMap = Dictionary(existing.map { ($0.recordName, $0) }, uniquingKeysWith: { first, _ in first })

        for pa in pas {
            let name = pa.id.recordName
            if let cached = existingMap[name] {
                cached.achievementRecordName = pa.achievement.recordID.recordName
                cached.profileRecordName = pa.profile.recordID.recordName
                cached.familyRecordName = pa.family.recordID.recordName
                cached.earnedDate = pa.earnedDate
            } else {
                context.insert(ProfileAchievementCache(from: pa))
            }
        }
        try? context.save()
    }

    func upsertNotificationPreferences(_ prefs: [NotificationPreference]) {
        let context = container.mainContext
        let existing = (try? context.fetch(FetchDescriptor<NotificationPreferenceCache>())) ?? []
        let existingMap = Dictionary(existing.map { ($0.recordName, $0) }, uniquingKeysWith: { first, _ in first })

        for pref in prefs {
            let name = pref.id.recordName
            if let cached = existingMap[name] {
                cached.profileRecordName = pref.profile.recordID.recordName
                cached.familyRecordName = pref.family.recordID.recordName
                cached.eventType = pref.eventType.rawValue
                cached.enabled = pref.enabled
                cached.pushEnabled = pref.pushEnabled
            } else {
                context.insert(NotificationPreferenceCache(from: pref))
            }
        }
        try? context.save()
    }

    // MARK: - Fetches

    func fetchQuests(family: String?, weekInRange: ClosedRange<Date>? = nil) -> [QuestCache] {
        let context = container.mainContext
        var descriptor = FetchDescriptor<QuestCache>(
            predicate: #Predicate { item in
                family == nil || item.familyRecordName == (family ?? "")
            }
        )
        if let range = weekInRange {
            let start = range.lowerBound
            let end = range.upperBound
            descriptor = FetchDescriptor<QuestCache>(
                predicate: #Predicate { item in
                    (family == nil || item.familyRecordName == (family ?? ""))
                        && item.weekOf >= start
                        && item.weekOf < end
                }
            )
        }
        return (try? context.fetch(descriptor)) ?? []
    }

    func fetchQuestCompletions(family: String?) -> [QuestCompletionCache] {
        let context = container.mainContext
        let descriptor = FetchDescriptor<QuestCompletionCache>(
            predicate: #Predicate { item in
                family == nil || item.familyRecordName == (family ?? "")
            }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func fetchProfile(recordName: String) -> ProfileCache? {
        let context = container.mainContext
        let descriptor = FetchDescriptor<ProfileCache>(
            predicate: #Predicate { $0.recordName == recordName }
        )
        return try? context.fetch(descriptor).first
    }

    func fetchProfiles(family: String?) -> [ProfileCache] {
        let context = container.mainContext
        let descriptor = FetchDescriptor<ProfileCache>(
            predicate: #Predicate { item in
                family == nil || item.familyRecordName == (family ?? "")
            }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func fetchQuestTemplates(family: String?) -> [QuestTemplateCache] {
        let context = container.mainContext
        let descriptor = FetchDescriptor<QuestTemplateCache>(
            predicate: #Predicate { item in
                family == nil || item.familyRecordName == (family ?? "")
            }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func fetchFamily(recordName: String) -> FamilyCache? {
        let context = container.mainContext
        let descriptor = FetchDescriptor<FamilyCache>(
            predicate: #Predicate { $0.recordName == recordName }
        )
        return try? context.fetch(descriptor).first
    }

    func fetchLedgerEntries(profileRecordName: String) -> [LedgerEntryCache] {
        let context = container.mainContext
        let descriptor = FetchDescriptor<LedgerEntryCache>(
            predicate: #Predicate { $0.profileRecordName == profileRecordName },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func fetchAllowancePeriods(profileRecordName: String) -> [AllowancePeriodCache] {
        let context = container.mainContext
        let descriptor = FetchDescriptor<AllowancePeriodCache>(
            predicate: #Predicate { $0.profileRecordName == profileRecordName },
            sortBy: [SortDescriptor(\.weekOf, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Family-scoped read of cached allowance periods (sorted newest-first),
    /// mirroring `fetchProfiles(family:)`. Used by the cache-first read path
    /// so callers can render past payouts synchronously while CloudKit lags.
    func fetchAllowancePeriods(family: String?) -> [AllowancePeriodCache] {
        let context = container.mainContext
        let descriptor = FetchDescriptor<AllowancePeriodCache>(
            predicate: #Predicate { item in
                family == nil || item.familyRecordName == (family ?? "")
            },
            sortBy: [SortDescriptor(\.weekOf, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func fetchAchievements(family: String?) -> [AchievementCache] {
        let context = container.mainContext
        let descriptor = FetchDescriptor<AchievementCache>(
            predicate: #Predicate { item in
                family == nil || item.familyRecordName == (family ?? "")
            }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func fetchProfileAchievements(profileRecordName: String) -> [ProfileAchievementCache] {
        let context = container.mainContext
        let descriptor = FetchDescriptor<ProfileAchievementCache>(
            predicate: #Predicate { $0.profileRecordName == profileRecordName },
            sortBy: [SortDescriptor(\.earnedDate, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func fetchNotificationPreferences(profileRecordName: String) -> [NotificationPreferenceCache] {
        let context = container.mainContext
        let descriptor = FetchDescriptor<NotificationPreferenceCache>(
            predicate: #Predicate { $0.profileRecordName == profileRecordName }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Invalidation

    func invalidateQuest(recordName: String) {
        let context = container.mainContext
        let descriptor = FetchDescriptor<QuestCache>(
            predicate: #Predicate { $0.recordName == recordName }
        )
        if let object = try? context.fetch(descriptor).first {
            context.delete(object)
            try? context.save()
        }
    }

    func invalidateQuestCompletion(recordName: String) {
        let context = container.mainContext
        let descriptor = FetchDescriptor<QuestCompletionCache>(
            predicate: #Predicate { $0.recordName == recordName }
        )
        if let object = try? context.fetch(descriptor).first {
            context.delete(object)
            try? context.save()
        }
    }

    func invalidateProfile(recordName: String) {
        let context = container.mainContext
        let descriptor = FetchDescriptor<ProfileCache>(
            predicate: #Predicate { $0.recordName == recordName }
        )
        if let object = try? context.fetch(descriptor).first {
            context.delete(object)
            try? context.save()
        }
    }

    func invalidateQuestTemplate(recordName: String) {
        let context = container.mainContext
        let descriptor = FetchDescriptor<QuestTemplateCache>(
            predicate: #Predicate { $0.recordName == recordName }
        )
        if let object = try? context.fetch(descriptor).first {
            context.delete(object)
            try? context.save()
        }
    }

    func invalidateLedgerEntry(recordName: String) {
        let context = container.mainContext
        let descriptor = FetchDescriptor<LedgerEntryCache>(
            predicate: #Predicate { $0.recordName == recordName }
        )
        if let object = try? context.fetch(descriptor).first {
            context.delete(object)
            try? context.save()
        }
    }

    func invalidateAllowancePeriod(recordName: String) {
        let context = container.mainContext
        let descriptor = FetchDescriptor<AllowancePeriodCache>(
            predicate: #Predicate { $0.recordName == recordName }
        )
        if let object = try? context.fetch(descriptor).first {
            context.delete(object)
            try? context.save()
        }
    }

    func invalidateAchievement(recordName: String) {
        let context = container.mainContext
        let descriptor = FetchDescriptor<AchievementCache>(
            predicate: #Predicate { $0.recordName == recordName }
        )
        if let object = try? context.fetch(descriptor).first {
            context.delete(object)
            try? context.save()
        }
    }

    func invalidateProfileAchievement(recordName: String) {
        let context = container.mainContext
        let descriptor = FetchDescriptor<ProfileAchievementCache>(
            predicate: #Predicate { $0.recordName == recordName }
        )
        if let object = try? context.fetch(descriptor).first {
            context.delete(object)
            try? context.save()
        }
    }

    func invalidateFamily(recordName: String) {
        let context = container.mainContext
        let descriptor = FetchDescriptor<FamilyCache>(
            predicate: #Predicate { $0.recordName == recordName }
        )
        if let object = try? context.fetch(descriptor).first {
            context.delete(object)
            try? context.save()
        }
    }

    func invalidateNotificationPreference(recordName: String) {
        let context = container.mainContext
        let descriptor = FetchDescriptor<NotificationPreferenceCache>(
            predicate: #Predicate { $0.recordName == recordName }
        )
        if let object = try? context.fetch(descriptor).first {
            context.delete(object)
            try? context.save()
        }
    }

    // MARK: - Bulk Clear

    func clearAll() {
        let context = container.mainContext
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
