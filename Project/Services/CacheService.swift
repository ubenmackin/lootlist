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
import Synchronization

@MainActor
@Observable
final class CacheService {
    let container: ModelContainer?
    var initializationError: Error?

    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "CacheService")
    private var isBatching = false

    /// Shared in-flight mutation registry. Mutation services
    /// register a `recordName` before their optimistic upsert and deregister it
    /// once the CloudKit save settles (success or terminal failure);
    /// `BackgroundCacheActor.batchUpsert*` consults this same instance so a
    /// background sync never clobbers an optimistically-written row with stale
    /// server data. `@ObservationIgnored` because it is shared concurrency
    /// infrastructure, not observable UI state.
    @ObservationIgnored
    let inFlightRegistry = InFlightMutationRegistry()

    // Test-only observation hook: records the `family` scope of every
    // `fetchLedgerEntries(profileRecordName:family:)` call so tests can assert
    // a mutation's optimistic snapshot and rollback re-fetch stay scoped to
    // the active family. Production code never reads this; it exists so the
    // family-scoping of the ledger snapshot can be verified rather than
    // inferred from cache contents (the snapshot is keyed by a freshly
    // generated record name, which no pre-existing row can match).
    // `@ObservationIgnored` because it is test infrastructure, not
    // observable UI state. Compiled out of release builds so a shipped app
    // never allocates it; it is only ever appended to and reset by
    // debug-build tests.
    #if DEBUG
        @ObservationIgnored
        var ledgerEntryFetchScopes: [String?] = []
    #endif

    /// Cancellable handle for the `ModelContext.didSave` observer task.
    /// Wrapped in a `Mutex` so `nonisolated deinit` can cancel the
    /// listener without touching main-actor-isolated state (same pattern as
    /// SyncEngine's sync task mutex).
    private let didSaveObserverMutex = Mutex<Task<Void, Never>?>(nil)

    /// Shorthand for `container.mainContext`. Used by every read/write on this
    /// service so the underlying access path lives in one place.
    var context: ModelContext? {
        container?.mainContext
    }

    init(inMemory: Bool = false) throws {
        let schema = Schema(LootListSchemaV4.models)
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
        installDidSaveObserver()
    }

    nonisolated deinit {
        didSaveObserverMutex.withLock { $0?.cancel() }
    }

    /// Installs the didSave observer: observes every `ModelContext.didSave` and,
    /// when the saved context is a background context of this container, forces
    /// `container.mainContext` to re-evaluate so `@Query` results update
    /// deterministically even when the OS misses automatic cross-context
    /// propagation. The listener runs as a `@MainActor` task (isolation
    /// inherited from this class), so the hop to main is implicit — no
    /// `@Sendable` closure capture of `self` is involved. Skipped when the
    /// container failed to initialize.
    private func installDidSaveObserver() {
        guard container != nil else { return }
        let task = Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(named: ModelContext.didSave) {
                guard let self,
                      let savedContext = notification.object as? ModelContext else { continue }
                // Main-context saves already re-fire @Query through normal
                // SwiftUI observation; only background-context saves need the
                // deterministic kick. Accessing `savedContext.container` is unsafe
                // across actor boundaries and crashes if `savedContext` is deallocating,
                // so we check pointer inequality against `mainContext`.
                guard savedContext !== container?.mainContext else { continue }
                refreshMainContextAfterBackgroundSave()
            }
        }
        didSaveObserverMutex.withLock { $0 = task }
    }

    /// Forces the main context to incorporate a background save:
    /// `processPendingChanges()` flushes queued remote-change notifications so
    /// `@Query` fetch results re-evaluate deterministically.
    private func refreshMainContextAfterBackgroundSave() {
        guard let container else { return }
        let mainContext = container.mainContext
        mainContext.processPendingChanges()
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

    // MARK: - Freshness Watermark

    private static let freshnessKeyPrefix = "cache_fresh_"

    /// Marks the cache as fully synced for a given family + entity type.
    /// Stored in UserDefaults (not SwiftData) so stamps survive cache purges
    /// and are cheap to read on every cache-first gate. Only SyncEngine writes
    /// stamps — after a successful `batchUpsert*` + `purgeMissing*` pass — so
    /// an absent stamp means "never fully synced" and cache-first reads must
    /// fall through to CloudKit.
    func markCacheFresh(familyRecordName: String, type: CachedRecordType, at date: Date = Date()) {
        UserDefaults.standard.set(date, forKey: freshnessKey(familyRecordName: familyRecordName, type: type))
    }

    /// Returns true when a successful sync pass has stamped this
    /// family + entity type. Absent stamps (never synced) and stamps cleared
    /// by `clearAll()` / `purgeFamily(recordName:)` read as stale.
    func isCacheFresh(familyRecordName: String, type: CachedRecordType) -> Bool {
        UserDefaults.standard.object(forKey: freshnessKey(familyRecordName: familyRecordName, type: type)) != nil
    }

    /// Removes the freshness stamp for one family + type.
    func invalidateFreshness(familyRecordName: String, type: CachedRecordType) {
        UserDefaults.standard.removeObject(forKey: freshnessKey(familyRecordName: familyRecordName, type: type))
    }

    /// Removes every freshness stamp (all families + types). Called by
    /// `clearAll()` so a wiped cache never serves a stale watermark.
    func invalidateAllFreshness() {
        let defaults = UserDefaults.standard
        let staleKeys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(Self.freshnessKeyPrefix) }
        for key in staleKeys {
            defaults.removeObject(forKey: key)
        }
    }

    /// Removes every freshness stamp scoped to a single family. Called by
    /// `purgeFamily(recordName:)` so a purged family never serves a stale
    /// watermark for the rows that were just deleted.
    func invalidateFreshness(forFamilyRecordName familyRecordName: String) {
        let defaults = UserDefaults.standard
        let prefix = "\(Self.freshnessKeyPrefix)\(familyRecordName)_"
        let staleKeys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }
        for key in staleKeys {
            defaults.removeObject(forKey: key)
        }
    }

    private func freshnessKey(familyRecordName: String, type: CachedRecordType) -> String {
        "\(Self.freshnessKeyPrefix)\(familyRecordName)_\(type.rawValue)"
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

    // changeTag is copied unconditionally — nil is a meaningful "no further tag" value that must propagate.

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
            existing.xpBanked = quest.xpBanked
            // `rarity` is intentionally NOT re-stamped: `rarityEnum` derives it
            // from `xpReward` at read time; the stored string is only a legacy
            // fallback for rows without a meaningful xpReward.
            existing.scheduleType = quest.scheduleType.rawValue
            existing.isAllOrNothing = quest.isAllOrNothing
            existing.approvalMode = quest.approvalMode.rawValue
            existing.descriptionText = quest.descriptionText
            existing.targetCount = quest.targetCount
            existing.createdByRecordName = quest.createdBy.recordID.recordName
            existing.changeTag = quest.changeTag
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
            existing.payoutDay = profile.payoutDay?.rawValue
            existing.changeTag = profile.changeTag
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
            existing.xpCredited = completion.xpCredited
            existing.changeTag = completion.changeTag
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
            existing.targetCount = template.targetCount
            existing.scheduleType = template.scheduleType.rawValue
            existing.isAllOrNothing = template.isAllOrNothing
            existing.approvalMode = template.approvalMode.rawValue
            existing.createdByRecordName = template.createdBy.recordID.recordName
            existing.changeTag = template.changeTag
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
            existing.payoutDay = family.payoutDay.rawValue
            existing.changeTag = family.changeTag
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
            existing.changeTag = entry.changeTag
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
            existing.changeTag = period.changeTag
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
            existing.changeTag = achievement.changeTag
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
            existing.changeTag = pref.changeTag
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
            existing.changeTag = pa.changeTag
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
                cached.xpBanked = quest.xpBanked
                // `rarity` is intentionally NOT re-stamped: `rarityEnum` derives
                // it from `xpReward` at read time; the stored string is only a
                // legacy fallback for rows without a meaningful xpReward.
                cached.scheduleType = quest.scheduleType.rawValue
                cached.isAllOrNothing = quest.isAllOrNothing
                cached.approvalMode = quest.approvalMode.rawValue
                cached.descriptionText = quest.descriptionText
                cached.targetCount = quest.targetCount
                cached.createdByRecordName = quest.createdBy.recordID.recordName
                cached.changeTag = quest.changeTag
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
                cached.changeTag = profile.changeTag
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
                cached.xpCredited = completion.xpCredited
                cached.changeTag = completion.changeTag
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
                cached.targetCount = template.targetCount
                cached.scheduleType = template.scheduleType.rawValue
                cached.isAllOrNothing = template.isAllOrNothing
                cached.approvalMode = template.approvalMode.rawValue
                cached.createdByRecordName = template.createdBy.recordID.recordName
                cached.changeTag = template.changeTag
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
                cached.changeTag = entry.changeTag
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
                cached.changeTag = period.changeTag
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
                cached.changeTag = achievement.changeTag
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
                cached.changeTag = pa.changeTag
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
                cached.changeTag = pref.changeTag
            } else {
                context.insert(NotificationPreferenceCache(from: pref))
            }
        }
        saveContext()
    }
}
