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

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "CacheService")
    private var isBatching = false

    /// Shorthand for `container.mainContext`. Used by every read/write on this
    /// service so the underlying access path lives in one place.
    var context: ModelContext? {
        container?.mainContext
    }

    init(inMemory: Bool = false) throws {
        let schema = Schema(LootListSchemaV1.models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        do {
            container = try ModelContainer(
                for: schema,
                migrationPlan: LootListMigrationPlan.self,
                configurations: config
            )
        } catch {
            logger.error("Failed to create ModelContainer: \(error)")
            container = nil
            initializationError = error
        }
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
            return false
        }
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
        if let items = try? context.fetch(FetchDescriptor<T>(predicate: predicate)) {
            for item in items {
                context.delete(item)
            }
        }
    }

    // MARK: - Upserts (single)

    // Synchronous @MainActor paths for optimistic UI writes by view models and services.
    // Background sync from CloudKit uses BackgroundCacheActor instead.

    func upsertQuest(_ quest: Quest, family _: String? = nil) {
        guard let context else { return }
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
            if let tag = quest.changeTag {
                existing.changeTag = tag
            }
        } else {
            context.insert(QuestCache(from: quest))
        }
        saveContext()
    }

    func upsertProfile(_ profile: Profile, family _: String? = nil) {
        guard let context else { return }
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
            existing.customAvatarImageData = profile.customAvatarImageData
            existing.isActive = profile.isActive
            existing.level = profile.level
            existing.iCloudUserRecordName = profile.iCloudUserID.recordName
            existing.avatarClass = profile.avatarClass?.rawValue
            existing.payoutPolicy = profile.payoutPolicy.rawValue
            if let tag = profile.changeTag {
                existing.changeTag = tag
            }
        } else {
            context.insert(ProfileCache(from: profile))
        }
        saveContext()
    }

    func upsertQuestCompletion(_ completion: QuestCompletion, family _: String? = nil) {
        guard let context else { return }
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
            existing.approvalMode = (completion.verificationStatus == .autoApproved)
                ? ApprovalMode.autoApprove.rawValue
                : ApprovalMode.parentVerify.rawValue
            existing.verifiedByRecordName = completion.verifiedBy?.recordID.recordName
            existing.verifiedDate = completion.verifiedDate
            if let tag = completion.changeTag {
                existing.changeTag = tag
            }
        } else {
            context.insert(QuestCompletionCache(from: completion))
        }
        saveContext()
    }

    func upsertQuestTemplate(_ template: QuestTemplate, family _: String? = nil) {
        guard let context else { return }
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
            if let tag = template.changeTag {
                existing.changeTag = tag
            }
        } else {
            context.insert(QuestTemplateCache(from: template))
        }
        saveContext()
    }

    func upsertFamily(_ family: Family) {
        guard let context else { return }
        let name = family.id.recordName
        let descriptor = FetchDescriptor<FamilyCache>(
            predicate: #Predicate { $0.recordName == name }
        )
        if let existing = try? context.fetch(descriptor).first {
            existing.name = family.name
            existing.createdByRecordName = family.createdBy.recordName
            existing.createdAt = family.createdAt
            existing.payoutPolicy = family.payoutPolicy.rawValue
            if let tag = family.changeTag {
                existing.changeTag = tag
            }
        } else {
            context.insert(FamilyCache(from: family))
        }
        saveContext()
    }

    func upsertLedgerEntry(_ entry: LedgerEntry) {
        guard let context else { return }
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
            if let tag = entry.changeTag {
                existing.changeTag = tag
            }
        } else {
            context.insert(LedgerEntryCache(from: entry))
        }
        saveContext()
    }

    func upsertAllowancePeriod(_ period: AllowancePeriod) {
        guard let context else { return }
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
            if let tag = period.changeTag {
                existing.changeTag = tag
            }
        } else {
            context.insert(AllowancePeriodCache(from: period))
        }
        saveContext()
    }

    func upsertAchievement(_ achievement: Achievement) {
        guard let context else { return }
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
            if let tag = achievement.changeTag {
                existing.changeTag = tag
            }
        } else {
            context.insert(AchievementCache(from: achievement))
        }
        saveContext()
    }

    func upsertNotificationPreference(_ pref: NotificationPreference) {
        guard let context else { return }
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
            if let tag = pref.changeTag {
                existing.changeTag = tag
            }
        } else {
            context.insert(NotificationPreferenceCache(from: pref))
        }
        saveContext()
    }

    func upsertProfileAchievement(_ pa: ProfileAchievement) {
        guard let context else { return }
        let name = pa.id.recordName
        let descriptor = FetchDescriptor<ProfileAchievementCache>(
            predicate: #Predicate { $0.recordName == name }
        )
        if let existing = try? context.fetch(descriptor).first {
            existing.achievementRecordName = pa.achievement.recordID.recordName
            existing.profileRecordName = pa.profile.recordID.recordName
            existing.familyRecordName = pa.family.recordID.recordName
            existing.earnedDate = pa.earnedDate
            if let tag = pa.changeTag {
                existing.changeTag = tag
            }
        } else {
            context.insert(ProfileAchievementCache(from: pa))
        }
        saveContext()
    }

    // MARK: - Batch Upserts

    func upsertQuests(_ quests: [Quest], family: String? = nil) {
        guard let context else { return }
        let existing: [QuestCache] = if let family {
            (try? context.fetch(FetchDescriptor<QuestCache>(
                predicate: #Predicate { $0.familyRecordName == family }
            ))) ?? []
        } else {
            (try? context.fetch(FetchDescriptor<QuestCache>())) ?? []
        }
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
                if let tag = quest.changeTag {
                    cached.changeTag = tag
                }
            } else {
                context.insert(QuestCache(from: quest))
            }
        }
        saveContext()
    }

    func upsertProfiles(_ profiles: [Profile], family: String? = nil) {
        guard let context else { return }
        let existing: [ProfileCache] = if let family {
            (try? context.fetch(FetchDescriptor<ProfileCache>(
                predicate: #Predicate { $0.familyRecordName == family }
            ))) ?? []
        } else {
            (try? context.fetch(FetchDescriptor<ProfileCache>())) ?? []
        }
        let existingMap = Dictionary(existing.map { ($0.recordName, $0) }, uniquingKeysWith: { first, _ in first })

        for profile in profiles {
            let name = profile.id.recordName
            if let cached = existingMap[name] {
                cached.familyRecordName = profile.family.recordID.recordName
                cached.displayName = profile.displayName
                cached.role = profile.role.rawValue
                cached.xpTotal = profile.xp
                cached.avatarName = profile.avatarPresetID
                cached.customAvatarImageData = profile.customAvatarImageData
                cached.isActive = profile.isActive
                cached.level = profile.level
                cached.iCloudUserRecordName = profile.iCloudUserID.recordName
                cached.avatarClass = profile.avatarClass?.rawValue
                cached.payoutPolicy = profile.payoutPolicy.rawValue
                if let tag = profile.changeTag {
                    cached.changeTag = tag
                }
            } else {
                context.insert(ProfileCache(from: profile))
            }
        }
        saveContext()
    }

    func upsertQuestCompletions(_ completions: [QuestCompletion], family: String? = nil) {
        guard let context else { return }
        let existing: [QuestCompletionCache] = if let family {
            (try? context.fetch(FetchDescriptor<QuestCompletionCache>(
                predicate: #Predicate { $0.familyRecordName == family }
            ))) ?? []
        } else {
            (try? context.fetch(FetchDescriptor<QuestCompletionCache>())) ?? []
        }
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
                cached.approvalMode = (completion.verificationStatus == .autoApproved)
                    ? ApprovalMode.autoApprove.rawValue
                    : ApprovalMode.parentVerify.rawValue
                cached.verifiedByRecordName = completion.verifiedBy?.recordID.recordName
                cached.verifiedDate = completion.verifiedDate
                if let tag = completion.changeTag {
                    cached.changeTag = tag
                }
            } else {
                context.insert(QuestCompletionCache(from: completion))
            }
        }
        saveContext()
    }

    func upsertQuestTemplates(_ templates: [QuestTemplate], family: String? = nil) {
        guard let context else { return }
        let existing: [QuestTemplateCache] = if let family {
            (try? context.fetch(FetchDescriptor<QuestTemplateCache>(
                predicate: #Predicate { $0.familyRecordName == family }
            ))) ?? []
        } else {
            (try? context.fetch(FetchDescriptor<QuestTemplateCache>())) ?? []
        }
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
                if let tag = template.changeTag {
                    cached.changeTag = tag
                }
            } else {
                context.insert(QuestTemplateCache(from: template))
            }
        }
        saveContext()
    }

    func upsertLedgerEntries(_ entries: [LedgerEntry], family: String? = nil) {
        guard let context else { return }
        let existing: [LedgerEntryCache] = if let family {
            (try? context.fetch(FetchDescriptor<LedgerEntryCache>(
                predicate: #Predicate { $0.familyRecordName == family }
            ))) ?? []
        } else {
            (try? context.fetch(FetchDescriptor<LedgerEntryCache>())) ?? []
        }
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
                if let tag = entry.changeTag {
                    cached.changeTag = tag
                }
            } else {
                context.insert(LedgerEntryCache(from: entry))
            }
        }
        saveContext()
    }

    func upsertAllowancePeriods(_ periods: [AllowancePeriod], family: String? = nil) {
        guard let context else { return }
        let existing: [AllowancePeriodCache] = if let family {
            (try? context.fetch(FetchDescriptor<AllowancePeriodCache>(
                predicate: #Predicate { $0.familyRecordName == family }
            ))) ?? []
        } else {
            (try? context.fetch(FetchDescriptor<AllowancePeriodCache>())) ?? []
        }
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
                if let tag = period.changeTag {
                    cached.changeTag = tag
                }
            } else {
                context.insert(AllowancePeriodCache(from: period))
            }
        }
        saveContext()
    }

    func upsertAchievements(_ achievements: [Achievement], family: String? = nil) {
        guard let context else { return }
        let existing: [AchievementCache] = if let family {
            (try? context.fetch(FetchDescriptor<AchievementCache>(
                predicate: #Predicate { $0.familyRecordName == family }
            ))) ?? []
        } else {
            (try? context.fetch(FetchDescriptor<AchievementCache>())) ?? []
        }
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
                if let tag = achievement.changeTag {
                    cached.changeTag = tag
                }
            } else {
                context.insert(AchievementCache(from: achievement))
            }
        }
        saveContext()
    }

    func upsertProfileAchievements(_ pas: [ProfileAchievement], family: String? = nil) {
        guard let context else { return }
        let existing: [ProfileAchievementCache] = if let family {
            (try? context.fetch(FetchDescriptor<ProfileAchievementCache>(
                predicate: #Predicate { $0.familyRecordName == family }
            ))) ?? []
        } else {
            (try? context.fetch(FetchDescriptor<ProfileAchievementCache>())) ?? []
        }
        let existingMap = Dictionary(existing.map { ($0.recordName, $0) }, uniquingKeysWith: { first, _ in first })

        for pa in pas {
            let name = pa.id.recordName
            if let cached = existingMap[name] {
                cached.achievementRecordName = pa.achievement.recordID.recordName
                cached.profileRecordName = pa.profile.recordID.recordName
                cached.familyRecordName = pa.family.recordID.recordName
                cached.earnedDate = pa.earnedDate
                if let tag = pa.changeTag {
                    cached.changeTag = tag
                }
            } else {
                context.insert(ProfileAchievementCache(from: pa))
            }
        }
        saveContext()
    }

    func upsertNotificationPreferences(_ prefs: [NotificationPreference], family: String? = nil) {
        guard let context else { return }
        let existing: [NotificationPreferenceCache] = if let family {
            (try? context.fetch(FetchDescriptor<NotificationPreferenceCache>(
                predicate: #Predicate { $0.familyRecordName == family }
            ))) ?? []
        } else {
            (try? context.fetch(FetchDescriptor<NotificationPreferenceCache>())) ?? []
        }
        let existingMap = Dictionary(existing.map { ($0.recordName, $0) }, uniquingKeysWith: { first, _ in first })

        for pref in prefs {
            let name = pref.id.recordName
            if let cached = existingMap[name] {
                cached.profileRecordName = pref.profile.recordID.recordName
                cached.familyRecordName = pref.family.recordID.recordName
                cached.eventType = pref.eventType.rawValue
                cached.enabled = pref.enabled
                cached.pushEnabled = pref.pushEnabled
                if let tag = pref.changeTag {
                    cached.changeTag = tag
                }
            } else {
                context.insert(NotificationPreferenceCache(from: pref))
            }
        }
        saveContext()
    }
}
