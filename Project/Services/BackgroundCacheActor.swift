//
//  BackgroundCacheActor.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import os
import SwiftData

@ModelActor
actor BackgroundCacheActor {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "BackgroundCacheActor")

    /// Custom initializer that disables SwiftData autosave on the backing
    /// `modelContext`. Uses a parameter label (`container:`) distinct from the
    /// `@ModelActor`-synthesized `init(modelContainer:)` to avoid an ambiguous
    /// overload diagnostic. This is the single source of truth for autosave
    /// disposition — method bodies no longer toggle `autosaveEnabled`.
    init(container: ModelContainer) {
        modelContainer = container
        let modelContext = ModelContext(container)
        modelContext.autosaveEnabled = false
        modelExecutor = DefaultSerialModelExecutor(modelContext: modelContext)
    }

    func batchUpsertQuests(_ quests: [Quest], familyRecordName: String? = nil) {
        let existing: [QuestCache] = if let family = familyRecordName {
            (try? modelContext.fetch(FetchDescriptor<QuestCache>(
                predicate: #Predicate { $0.familyRecordName == family }
            ))) ?? []
        } else {
            (try? modelContext.fetch(FetchDescriptor<QuestCache>())) ?? []
        }
        let byName = Dictionary(uniqueKeysWithValues: existing.map { ($0.recordName, $0) })
        for quest in quests {
            let name = quest.id.recordName
            if let target = byName[name] {
                target.familyRecordName = quest.family.recordID.recordName
                target.assigneeRecordName = quest.assignee.recordID.recordName
                target.templateRecordName = quest.template.recordID.recordName
                target.weekOf = quest.weekOf
                target.questName = quest.displayName
                target.isActive = quest.active
                target.goldReward = quest.goldReward
                target.xpReward = quest.xpReward
                target.rarity = quest.rarity.rawValue
                target.scheduleType = quest.scheduleType.rawValue
                target.isAllOrNothing = quest.isAllOrNothing
                target.approvalMode = quest.approvalMode.rawValue
                target.descriptionText = quest.descriptionText
                target.createdByRecordName = quest.createdBy.recordID.recordName
                if let tag = quest.changeTag {
                    target.changeTag = tag
                }
            } else {
                modelContext.insert(QuestCache(from: quest))
            }
        }
        saveContext()
    }

    func batchUpsertProfiles(_ profiles: [Profile], familyRecordName: String? = nil) {
        let existing: [ProfileCache] = if let family = familyRecordName {
            (try? modelContext.fetch(FetchDescriptor<ProfileCache>(
                predicate: #Predicate { $0.familyRecordName == family }
            ))) ?? []
        } else {
            (try? modelContext.fetch(FetchDescriptor<ProfileCache>())) ?? []
        }
        let byName = Dictionary(uniqueKeysWithValues: existing.map { ($0.recordName, $0) })
        for profile in profiles {
            let name = profile.id.recordName
            if let target = byName[name] {
                target.familyRecordName = profile.family.recordID.recordName
                target.displayName = profile.displayName
                target.role = profile.role.rawValue
                target.xpTotal = profile.xp
                target.avatarName = profile.avatarPresetID
                target.customAvatarImageData = profile.customAvatarImageData
                target.isActive = profile.isActive
                target.level = profile.level
                target.iCloudUserRecordName = profile.iCloudUserID.recordName
                target.avatarClass = profile.avatarClass?.rawValue
                target.payoutPolicy = profile.payoutPolicy.rawValue
                if let tag = profile.changeTag {
                    target.changeTag = tag
                }
            } else {
                modelContext.insert(ProfileCache(from: profile))
            }
        }
        saveContext()
    }

    func batchUpsertQuestCompletions(_ completions: [QuestCompletion], familyRecordName: String? = nil) {
        let existing: [QuestCompletionCache] = if let family = familyRecordName {
            (try? modelContext.fetch(FetchDescriptor<QuestCompletionCache>(
                predicate: #Predicate { $0.familyRecordName == family }
            ))) ?? []
        } else {
            (try? modelContext.fetch(FetchDescriptor<QuestCompletionCache>())) ?? []
        }
        let byName = Dictionary(uniqueKeysWithValues: existing.map { ($0.recordName, $0) })
        for completion in completions {
            let name = completion.id.recordName
            if let target = byName[name] {
                target.questRecordName = completion.quest.recordID.recordName
                target.familyRecordName = completion.family.recordID.recordName
                target.completerRecordName = completion.completedBy.recordID.recordName
                target.completedDate = completion.completedDate
                target.weekOf = completion.weekOf
                target.verificationStatus = completion.verificationStatus.rawValue
                target.approvalMode = (completion.verificationStatus == .autoApproved)
                    ? ApprovalMode.autoApprove.rawValue
                    : ApprovalMode.parentVerify.rawValue
                target.verifiedByRecordName = completion.verifiedBy?.recordID.recordName
                target.verifiedDate = completion.verifiedDate
                if let tag = completion.changeTag {
                    target.changeTag = tag
                }
            } else {
                modelContext.insert(QuestCompletionCache(from: completion))
            }
        }
        saveContext()
    }

    func batchUpsertQuestTemplates(_ templates: [QuestTemplate], familyRecordName: String? = nil) {
        let existing: [QuestTemplateCache] = if let family = familyRecordName {
            (try? modelContext.fetch(FetchDescriptor<QuestTemplateCache>(
                predicate: #Predicate { $0.familyRecordName == family }
            ))) ?? []
        } else {
            (try? modelContext.fetch(FetchDescriptor<QuestTemplateCache>())) ?? []
        }
        let byName = Dictionary(uniqueKeysWithValues: existing.map { ($0.recordName, $0) })
        for template in templates {
            let name = template.id.recordName
            if let target = byName[name] {
                target.familyRecordName = template.family.recordID.recordName
                target.name = template.name
                target.isActive = template.isActive
                target.goldReward = template.defaultGold
                target.xpReward = template.xpReward
                target.rarity = template.rarity.rawValue
                target.specificDays = template.specificDays.isEmpty ? nil : template.specificDays
                target.templateDescription = template.description
                target.scheduleType = template.scheduleType.rawValue
                target.isAllOrNothing = template.isAllOrNothing
                target.approvalMode = template.approvalMode.rawValue
                target.createdByRecordName = template.createdBy.recordID.recordName
                if let tag = template.changeTag {
                    target.changeTag = tag
                }
            } else {
                modelContext.insert(QuestTemplateCache(from: template))
            }
        }
        saveContext()
    }

    func batchUpsertLedgerEntries(_ entries: [LedgerEntry], familyRecordName: String? = nil) {
        let existing: [LedgerEntryCache] = if let family = familyRecordName {
            (try? modelContext.fetch(FetchDescriptor<LedgerEntryCache>(
                predicate: #Predicate { $0.familyRecordName == family }
            ))) ?? []
        } else {
            (try? modelContext.fetch(FetchDescriptor<LedgerEntryCache>())) ?? []
        }
        let byName = Dictionary(uniqueKeysWithValues: existing.map { ($0.recordName, $0) })
        for entry in entries {
            let name = entry.id.recordName
            if let target = byName[name] {
                target.profileRecordName = entry.profile.recordID.recordName
                target.familyRecordName = entry.family.recordID.recordName
                target.amount = entry.amount
                target.entryDescription = entry.description
                target.date = entry.date
                target.source = entry.source
                if let tag = entry.changeTag {
                    target.changeTag = tag
                }
            } else {
                modelContext.insert(LedgerEntryCache(from: entry))
            }
        }
        saveContext()
    }

    func batchUpsertAllowancePeriods(_ periods: [AllowancePeriod], familyRecordName: String? = nil) {
        let existing: [AllowancePeriodCache] = if let family = familyRecordName {
            (try? modelContext.fetch(FetchDescriptor<AllowancePeriodCache>(
                predicate: #Predicate { $0.familyRecordName == family }
            ))) ?? []
        } else {
            (try? modelContext.fetch(FetchDescriptor<AllowancePeriodCache>())) ?? []
        }
        let byName = Dictionary(uniqueKeysWithValues: existing.map { ($0.recordName, $0) })
        for period in periods {
            let name = period.id.recordName
            if let target = byName[name] {
                target.profileRecordName = period.profile.recordID.recordName
                target.familyRecordName = period.family.recordID.recordName
                target.weekOf = period.weekOf
                target.status = period.status.rawValue
                target.totalEarned = period.totalEarned
                target.questsCompleted = period.questsCompleted
                target.questsTotal = period.questsTotal
                target.paidDate = period.paidDate
                target.paidAmount = period.paidAmount
                if let tag = period.changeTag {
                    target.changeTag = tag
                }
            } else {
                modelContext.insert(AllowancePeriodCache(from: period))
            }
        }
        saveContext()
    }

    func batchUpsertAchievements(_ achievements: [Achievement], familyRecordName: String? = nil) {
        let existing: [AchievementCache] = if let family = familyRecordName {
            (try? modelContext.fetch(FetchDescriptor<AchievementCache>(
                predicate: #Predicate { $0.familyRecordName == family }
            ))) ?? []
        } else {
            (try? modelContext.fetch(FetchDescriptor<AchievementCache>())) ?? []
        }
        let byName = Dictionary(uniqueKeysWithValues: existing.map { ($0.recordName, $0) })
        for achievement in achievements {
            let name = achievement.id.recordName
            if let target = byName[name] {
                target.familyRecordName = achievement.family.recordID.recordName
                target.name = achievement.name
                target.achievementDescription = achievement.description
                target.iconSystemName = achievement.iconSystemName
                target.category = achievement.category.rawValue
                target.requirementType = achievement.requirementType.rawValue
                target.requirementValue = achievement.requirementValue
                if let tag = achievement.changeTag {
                    target.changeTag = tag
                }
            } else {
                modelContext.insert(AchievementCache(from: achievement))
            }
        }
        saveContext()
    }

    func batchUpsertProfileAchievements(_ pas: [ProfileAchievement], familyRecordName: String? = nil) {
        let existing: [ProfileAchievementCache] = if let family = familyRecordName {
            (try? modelContext.fetch(FetchDescriptor<ProfileAchievementCache>(
                predicate: #Predicate { $0.familyRecordName == family }
            ))) ?? []
        } else {
            (try? modelContext.fetch(FetchDescriptor<ProfileAchievementCache>())) ?? []
        }
        let byName = Dictionary(uniqueKeysWithValues: existing.map { ($0.recordName, $0) })
        for pa in pas {
            let name = pa.id.recordName
            if let target = byName[name] {
                target.achievementRecordName = pa.achievement.recordID.recordName
                target.profileRecordName = pa.profile.recordID.recordName
                target.familyRecordName = pa.family.recordID.recordName
                target.earnedDate = pa.earnedDate
                if let tag = pa.changeTag {
                    target.changeTag = tag
                }
            } else {
                modelContext.insert(ProfileAchievementCache(from: pa))
            }
        }
        saveContext()
    }

    func batchUpsertFamilies(_ families: [Family]) {
        let existing = (try? modelContext.fetch(FetchDescriptor<FamilyCache>())) ?? []
        let byName = Dictionary(uniqueKeysWithValues: existing.map { ($0.recordName, $0) })
        for family in families {
            let name = family.id.recordName
            if let target = byName[name] {
                target.name = family.name
                target.createdByRecordName = family.createdBy.recordName
                target.createdAt = family.createdAt
                target.payoutPolicy = family.payoutPolicy.rawValue
                if let tag = family.changeTag {
                    target.changeTag = tag
                }
            } else {
                modelContext.insert(FamilyCache(from: family))
            }
        }
        saveContext()
    }

    func batchUpsertNotificationPreferences(_ prefs: [NotificationPreference], familyRecordName: String? = nil) {
        let existing: [NotificationPreferenceCache] = if let family = familyRecordName {
            (try? modelContext.fetch(FetchDescriptor<NotificationPreferenceCache>(
                predicate: #Predicate { $0.familyRecordName == family }
            ))) ?? []
        } else {
            (try? modelContext.fetch(FetchDescriptor<NotificationPreferenceCache>())) ?? []
        }
        let byName = Dictionary(uniqueKeysWithValues: existing.map { ($0.recordName, $0) })
        for pref in prefs {
            let name = pref.id.recordName
            if let target = byName[name] {
                target.profileRecordName = pref.profile.recordID.recordName
                target.familyRecordName = pref.family.recordID.recordName
                target.eventType = pref.eventType.rawValue
                target.enabled = pref.enabled
                target.pushEnabled = pref.pushEnabled
                if let tag = pref.changeTag {
                    target.changeTag = tag
                }
            } else {
                modelContext.insert(NotificationPreferenceCache(from: pref))
            }
        }
        saveContext()
    }

    func purgeMissingQuests(validRecordNames: Set<String>, familyRecordName: String? = nil) {
        let existing: [QuestCache] = if let family = familyRecordName {
            (try? modelContext.fetch(FetchDescriptor<QuestCache>(
                predicate: #Predicate { $0.familyRecordName == family }
            ))) ?? []
        } else {
            (try? modelContext.fetch(FetchDescriptor<QuestCache>())) ?? []
        }
        for cached in existing where !validRecordNames.contains(cached.recordName) {
            modelContext.delete(cached)
        }
        saveContext()
    }

    func purgeMissingProfiles(validRecordNames: Set<String>, familyRecordName: String? = nil) {
        let existing: [ProfileCache] = if let family = familyRecordName {
            (try? modelContext.fetch(FetchDescriptor<ProfileCache>(
                predicate: #Predicate { $0.familyRecordName == family }
            ))) ?? []
        } else {
            (try? modelContext.fetch(FetchDescriptor<ProfileCache>())) ?? []
        }
        for cached in existing where !validRecordNames.contains(cached.recordName) {
            modelContext.delete(cached)
        }
        saveContext()
    }

    func purgeMissingQuestCompletions(validRecordNames: Set<String>, familyRecordName: String? = nil) {
        let existing: [QuestCompletionCache] = if let family = familyRecordName {
            (try? modelContext.fetch(FetchDescriptor<QuestCompletionCache>(
                predicate: #Predicate { $0.familyRecordName == family }
            ))) ?? []
        } else {
            (try? modelContext.fetch(FetchDescriptor<QuestCompletionCache>())) ?? []
        }
        for cached in existing where !validRecordNames.contains(cached.recordName) {
            modelContext.delete(cached)
        }
        saveContext()
    }

    func purgeMissingQuestTemplates(validRecordNames: Set<String>, familyRecordName: String? = nil) {
        let existing: [QuestTemplateCache] = if let family = familyRecordName {
            (try? modelContext.fetch(FetchDescriptor<QuestTemplateCache>(
                predicate: #Predicate { $0.familyRecordName == family }
            ))) ?? []
        } else {
            (try? modelContext.fetch(FetchDescriptor<QuestTemplateCache>())) ?? []
        }
        for cached in existing where !validRecordNames.contains(cached.recordName) {
            modelContext.delete(cached)
        }
        saveContext()
    }

    func purgeMissingLedgerEntries(validRecordNames: Set<String>, familyRecordName: String? = nil) {
        let existing: [LedgerEntryCache] = if let family = familyRecordName {
            (try? modelContext.fetch(FetchDescriptor<LedgerEntryCache>(
                predicate: #Predicate { $0.familyRecordName == family }
            ))) ?? []
        } else {
            (try? modelContext.fetch(FetchDescriptor<LedgerEntryCache>())) ?? []
        }
        for cached in existing where !validRecordNames.contains(cached.recordName) {
            modelContext.delete(cached)
        }
        saveContext()
    }

    func purgeMissingAllowancePeriods(validRecordNames: Set<String>, familyRecordName: String? = nil) {
        let existing: [AllowancePeriodCache] = if let family = familyRecordName {
            (try? modelContext.fetch(FetchDescriptor<AllowancePeriodCache>(
                predicate: #Predicate { $0.familyRecordName == family }
            ))) ?? []
        } else {
            (try? modelContext.fetch(FetchDescriptor<AllowancePeriodCache>())) ?? []
        }
        for cached in existing where !validRecordNames.contains(cached.recordName) {
            modelContext.delete(cached)
        }
        saveContext()
    }

    func purgeMissingAchievements(validRecordNames: Set<String>, familyRecordName: String? = nil) {
        let existing: [AchievementCache] = if let family = familyRecordName {
            (try? modelContext.fetch(FetchDescriptor<AchievementCache>(
                predicate: #Predicate { $0.familyRecordName == family }
            ))) ?? []
        } else {
            (try? modelContext.fetch(FetchDescriptor<AchievementCache>())) ?? []
        }
        for cached in existing where !validRecordNames.contains(cached.recordName) {
            modelContext.delete(cached)
        }
        saveContext()
    }

    func purgeMissingProfileAchievements(validRecordNames: Set<String>, familyRecordName: String? = nil) {
        let existing: [ProfileAchievementCache] = if let family = familyRecordName {
            (try? modelContext.fetch(FetchDescriptor<ProfileAchievementCache>(
                predicate: #Predicate { $0.familyRecordName == family }
            ))) ?? []
        } else {
            (try? modelContext.fetch(FetchDescriptor<ProfileAchievementCache>())) ?? []
        }
        for cached in existing where !validRecordNames.contains(cached.recordName) {
            modelContext.delete(cached)
        }
        saveContext()
    }

    func purgeMissingFamilies(validRecordNames: Set<String>) {
        let existing = (try? modelContext.fetch(FetchDescriptor<FamilyCache>())) ?? []
        for cached in existing where !validRecordNames.contains(cached.recordName) {
            modelContext.delete(cached)
        }
        saveContext()
    }

    func purgeMissingNotificationPreferences(validRecordNames: Set<String>, familyRecordName: String? = nil) {
        let existing: [NotificationPreferenceCache] = if let family = familyRecordName {
            (try? modelContext.fetch(FetchDescriptor<NotificationPreferenceCache>(
                predicate: #Predicate { $0.familyRecordName == family }
            ))) ?? []
        } else {
            (try? modelContext.fetch(FetchDescriptor<NotificationPreferenceCache>())) ?? []
        }
        for cached in existing where !validRecordNames.contains(cached.recordName) {
            modelContext.delete(cached)
        }
        saveContext()
    }

    /// Backfills `targetCount` to `1` for any `QuestCache` or `QuestTemplateCache`
    /// rows where the value is nil/zero/unset. Runs globally across all families
    /// by `@Attribute(.unique) recordName` — this is a one-time migration for
    /// pre-`targetCount` installs whose cache was persisted before the field
    /// existed. New rows always carry the `targetCount = 1` default from their
    /// `init`, so they are left untouched. Idempotent: rows already carrying a
    /// positive `targetCount` are never clobbered.
    func backfillTargetCountGlobally() {
        // QuestCache — iterate by recordName (global, not per-family).
        let quests = (try? modelContext.fetch(FetchDescriptor<QuestCache>())) ?? []
        for quest in quests where quest.targetCount <= 0 {
            quest.targetCount = 1
        }

        // QuestTemplateCache — same global-by-recordName iteration.
        let templates = (try? modelContext.fetch(FetchDescriptor<QuestTemplateCache>())) ?? []
        for template in templates where template.targetCount <= 0 {
            template.targetCount = 1
        }

        saveContext()
    }

    func deleteRecord(recordName: String, type: CachedRecordType) {
        if !deleteCoreRecord(recordName: recordName, type: type) {
            deleteSecondaryRecord(recordName: recordName, type: type)
        }
        saveContext()
    }

    @discardableResult
    private func deleteCoreRecord(recordName: String, type: CachedRecordType) -> Bool {
        switch type {
        case .quest:
            if let obj = (try? modelContext.fetch(FetchDescriptor<QuestCache>(predicate: #Predicate { $0.recordName == recordName })))?.first {
                modelContext.delete(obj)
            }
            return true
        case .profile:
            if let obj = (try? modelContext.fetch(FetchDescriptor<ProfileCache>(predicate: #Predicate { $0.recordName == recordName })))?.first {
                modelContext.delete(obj)
            }
            return true
        case .questCompletion:
            if let obj = (try? modelContext.fetch(FetchDescriptor<QuestCompletionCache>(predicate: #Predicate { $0.recordName == recordName })))?.first {
                modelContext.delete(obj)
            }
            return true
        case .questTemplate:
            if let obj = (try? modelContext.fetch(FetchDescriptor<QuestTemplateCache>(predicate: #Predicate { $0.recordName == recordName })))?.first {
                modelContext.delete(obj)
            }
            return true
        case .ledgerEntry:
            if let obj = (try? modelContext.fetch(FetchDescriptor<LedgerEntryCache>(predicate: #Predicate { $0.recordName == recordName })))?.first {
                modelContext.delete(obj)
            }
            return true
        case .family, .allowancePeriod, .achievement, .profileAchievement, .notificationPreference:
            // Core record types only — secondary-only types fall through to
            // `deleteSecondaryRecord`. Returning false here routes the caller
            // onward without deleting anything.
            return false
        }
    }

    private func deleteSecondaryRecord(recordName: String, type: CachedRecordType) {
        switch type {
        case .allowancePeriod:
            if let obj = (try? modelContext.fetch(FetchDescriptor<AllowancePeriodCache>(predicate: #Predicate { $0.recordName == recordName })))?.first {
                modelContext.delete(obj)
            }
            return
        case .achievement:
            if let obj = (try? modelContext.fetch(FetchDescriptor<AchievementCache>(predicate: #Predicate { $0.recordName == recordName })))?.first {
                modelContext.delete(obj)
            }
            return
        case .profileAchievement:
            if let obj = (try? modelContext.fetch(FetchDescriptor<ProfileAchievementCache>(predicate: #Predicate { $0.recordName == recordName })))?.first {
                modelContext.delete(obj)
            }
            return
        case .family:
            if let obj = (try? modelContext.fetch(FetchDescriptor<FamilyCache>(predicate: #Predicate { $0.recordName == recordName })))?.first {
                modelContext.delete(obj)
            }
            return
        case .notificationPreference:
            if let obj = (try? modelContext.fetch(FetchDescriptor<NotificationPreferenceCache>(predicate: #Predicate { $0.recordName == recordName })))?.first {
                modelContext.delete(obj)
            }
            return
        case .profile, .quest, .questCompletion, .questTemplate, .ledgerEntry:
            return
        }
    }

    private func saveContext() {
        do {
            try modelContext.save()
        } catch {
            logger.error("Failed to save background context: \(error, privacy: .private)")
        }
    }
}
