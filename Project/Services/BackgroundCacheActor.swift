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

/// Sendable descriptor for one server-stamped system-field refresh on an
/// existing cache row. Carries only plain values so a whole save round-trip
/// can cross to the background actor and commit under a single context save
/// instead of one save per record.
struct SystemFieldRefresh: Sendable {
    let recordName: String
    let type: CachedRecordType
    let changeTag: String?
    let encodedSystemFields: Data?
}

/// Result of a system-field refresh pass. A Bool return cannot separate "no
/// cached row matched" (legal — rows may have been deleted locally mid-flight)
/// from "the context save failed" (a real cache-write failure), and conflating
/// them would hide genuine persistence errors from sync accounting.
enum SystemFieldRefreshOutcome: Sendable {
    case updated
    case noMatches
    case saveFailed
}

@ModelActor
actor BackgroundCacheActor {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "BackgroundCacheActor")

    init(container: ModelContainer) {
        modelContainer = container
        let modelContext = ModelContext(container)
        modelContext.autosaveEnabled = false
        modelExecutor = DefaultSerialModelExecutor(modelContext: modelContext)
    }

    // MARK: - Generic batch helpers

    @discardableResult
    private func batchUpsert<T: CacheMergeable>(_: T.Type, _ items: [T.DomainModel], familyRecordName: String?) async -> Bool {
        let ok = await performUpsert(T.self, items, familyRecordName: familyRecordName, logLabel: "batchUpsert")
        guard ok else { return false }
        return saveContext()
    }

    private func purgeMissing<T: CacheMergeable>(
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
        saveContext()
    }

    // MARK: - Batch upserts (public API preserved as thin wrappers)

    @discardableResult
    func batchUpsertQuests(_ quests: [Quest], familyRecordName: String? = nil) async -> Bool {
        await batchUpsert(QuestCache.self, quests, familyRecordName: familyRecordName)
    }

    func backfillQuestNames(_ quests: [Quest], cloudKit: any CloudKitServiceProtocol) async -> [Quest] {
        let nameless = quests.filter { $0.name == nil }
        guard !nameless.isEmpty else { return quests }
        let recordNames = Set(nameless.map(\.template.recordID))
        var templatesByID: [CKRecord.ID: QuestTemplate] = [:]
        for recordID in recordNames {
            do { templatesByID[recordID] = try await cloudKit.fetch(QuestTemplate.self, id: recordID) } catch {
                logger.debug("Failed to fetch template for backfill \(recordID.recordName, privacy: .private): \(error, privacy: .private)")
            }
        }
        return quests.map { quest in
            guard quest.name == nil, let template = templatesByID[quest.template.recordID] else { return quest }
            var updated = quest
            updated.name = template.name
            return updated
        }
    }

    @discardableResult
    func batchUpsertProfiles(_ profiles: [Profile], familyRecordName: String? = nil) async -> Bool {
        await batchUpsert(ProfileCache.self, profiles, familyRecordName: familyRecordName)
    }

    @discardableResult
    func batchUpsertQuestCompletions(_ completions: [QuestCompletion], familyRecordName: String? = nil) async -> Bool {
        await batchUpsert(QuestCompletionCache.self, completions, familyRecordName: familyRecordName)
    }

    @discardableResult
    func batchUpsertQuestTemplates(_ templates: [QuestTemplate], familyRecordName: String? = nil) async -> Bool {
        await batchUpsert(QuestTemplateCache.self, templates, familyRecordName: familyRecordName)
    }

    @discardableResult
    func batchUpsertLedgerEntries(_ entries: [LedgerEntry], familyRecordName: String? = nil) async -> Bool {
        await batchUpsert(LedgerEntryCache.self, entries, familyRecordName: familyRecordName)
    }

    @discardableResult
    func batchUpsertAllowancePeriods(_ periods: [AllowancePeriod], familyRecordName: String? = nil) async -> Bool {
        await batchUpsert(AllowancePeriodCache.self, periods, familyRecordName: familyRecordName)
    }

    @discardableResult
    func batchUpsertAchievements(_ achievements: [Achievement], familyRecordName: String? = nil) async -> Bool {
        await batchUpsert(AchievementCache.self, achievements, familyRecordName: familyRecordName)
    }

    @discardableResult
    func batchUpsertProfileAchievements(_ pas: [ProfileAchievement], familyRecordName: String? = nil) async -> Bool {
        await batchUpsert(ProfileAchievementCache.self, pas, familyRecordName: familyRecordName)
    }

    @discardableResult
    func batchUpsertFamilies(_ families: [Family]) async -> Bool {
        await batchUpsert(FamilyCache.self, families, familyRecordName: nil)
    }

    @discardableResult
    func batchUpsertNotificationPreferences(_ prefs: [NotificationPreference], familyRecordName: String? = nil) async -> Bool {
        await batchUpsert(NotificationPreferenceCache.self, prefs, familyRecordName: familyRecordName)
    }

    @discardableResult
    func batchUpsertGemLedgers(_ entries: [GemLedger], familyRecordName: String? = nil) async -> Bool {
        await batchUpsert(GemLedgerCache.self, entries, familyRecordName: familyRecordName)
    }

    // MARK: - Atomic gem credit

    /// Delegates to shared helper so ledger/profile stay in one transaction
    /// and idempotency via deterministic ledger ID is enforced once.
    @discardableResult
    func atomicallyApplyGemCredit(ledger: GemLedger, profile: Profile) async -> Bool {
        guard sharedGemCreditPrepare(
            context: modelContext,
            ledger: ledger,
            profile: profile
        ) else { return false }
        return saveContext()
    }

    @discardableResult
    func batchUpsertRewardEvents(_ events: [RewardEvent], familyRecordName: String? = nil) async -> Bool {
        await batchUpsert(RewardEventCache.self, events, familyRecordName: familyRecordName)
    }

    private struct ParsedBatch: Sendable {
        var families: [Family] = []
        var profiles: [Profile] = []
        var quests: [Quest] = []
        var templates: [QuestTemplate] = []
        var completions: [QuestCompletion] = []
        var ledgerEntries: [LedgerEntry] = []
        var periods: [AllowancePeriod] = []
        var achievements: [Achievement] = []
        var profileAchievements: [ProfileAchievement] = []
        var notificationPrefs: [NotificationPreference] = []
        var rewardEvents: [RewardEvent] = []
        var gemLedgers: [GemLedger] = []

        mutating func append(_ record: ParsedRecord) {
            switch record {
            case let .family(item): families.append(item)
            case let .profile(item): profiles.append(item)
            case let .quest(item): quests.append(item)
            case let .questTemplate(item): templates.append(item)
            case let .questCompletion(item): completions.append(item)
            case let .ledgerEntry(item): ledgerEntries.append(item)
            case let .allowancePeriod(item): periods.append(item)
            case let .achievement(item): achievements.append(item)
            case let .profileAchievement(item): profileAchievements.append(item)
            case let .notificationPreference(item): notificationPrefs.append(item)
            case let .rewardEvent(item): rewardEvents.append(item)
            case let .gemLedger(item): gemLedgers.append(item)
            case .ignoredSystemRecord, .parseFailure: break
            }
        }
    }

    // MARK: - Atomic batch (single-save) + shared serialization

    @discardableResult
    func batchUpsertParsedRecords(_ records: [ParsedRecord]) async -> Bool {
        var batch = ParsedBatch()
        for record in records {
            batch.append(record)
        }
        let capturedBatch = batch
        return await SerialMutationQueue.shared.write {
            await self.commitParsedBatch(capturedBatch)
        }
    }

    /// Single-transaction commit: accumulates all inserts/updates across
    /// ParsedBatch in this actor's single ModelContext without intermediate
    /// saves, then calls saveContext() exactly once. Two-phase ordering
    /// (families/profiles first for FK parent) is preserved but the save is
    /// deferred to ensure @Query observes the batch atomically.
    private func commitParsedBatch(_ batch: ParsedBatch) async -> Bool {
        var success = true
        success = await commitCoreEntitiesDeferred(batch) && success
        success = await commitSecondaryEntitiesDeferred(batch) && success
        let saved = saveContext()
        return saved && success
    }

    private func commitCoreEntitiesDeferred(_ batch: ParsedBatch) async -> Bool {
        var success = true
        if !batch.families.isEmpty {
            success = await batchUpsertWithoutSave(FamilyCache.self, batch.families, familyRecordName: nil) && success
        }
        if !batch.profiles.isEmpty {
            success = await batchUpsertWithoutSave(ProfileCache.self, batch.profiles, familyRecordName: nil) && success
        }
        if !batch.quests.isEmpty {
            success = await batchUpsertWithoutSave(QuestCache.self, batch.quests, familyRecordName: nil) && success
        }
        if !batch.templates.isEmpty {
            success = await batchUpsertWithoutSave(QuestTemplateCache.self, batch.templates, familyRecordName: nil) && success
        }
        if !batch.completions.isEmpty {
            success = await batchUpsertWithoutSave(QuestCompletionCache.self, batch.completions, familyRecordName: nil) && success
            success = await reconcileStoredRewardEventsWithoutSave(for: batch.completions) && success
        }
        return success
    }

    private func commitSecondaryEntitiesDeferred(_ batch: ParsedBatch) async -> Bool {
        var success = true
        if !batch.ledgerEntries.isEmpty {
            success = await batchUpsertWithoutSave(LedgerEntryCache.self, batch.ledgerEntries, familyRecordName: nil) && success
        }
        if !batch.periods.isEmpty {
            success = await batchUpsertWithoutSave(AllowancePeriodCache.self, batch.periods, familyRecordName: nil) && success
        }
        if !batch.achievements.isEmpty {
            success = await batchUpsertWithoutSave(AchievementCache.self, batch.achievements, familyRecordName: nil) && success
        }
        if !batch.profileAchievements.isEmpty {
            success = await batchUpsertWithoutSave(ProfileAchievementCache.self, batch.profileAchievements, familyRecordName: nil) && success
        }
        if !batch.notificationPrefs.isEmpty {
            success = await batchUpsertWithoutSave(NotificationPreferenceCache.self, batch.notificationPrefs, familyRecordName: nil) && success
        }
        if !batch.gemLedgers.isEmpty {
            success = await batchUpsertWithoutSave(GemLedgerCache.self, batch.gemLedgers, familyRecordName: nil) && success
        }
        if !batch.rewardEvents.isEmpty {
            success = await batchUpsertWithoutSave(RewardEventCache.self, batch.rewardEvents, familyRecordName: nil) && success
            success = await reconcileRewardEventsWithoutSave(batch.rewardEvents) && success
        }
        return success
    }

    /// Shared upsert core: mutates the actor's ModelContext without saving so
    /// callers decide when to commit — single-type paths save immediately,
    /// while multi-type batches coalesce into one saveContext() at the
    /// transaction boundary. `logLabel` keeps log output identical to the
    /// original per-path messages.
    private func performUpsert<T: CacheMergeable>(
        _: T.Type,
        _ items: [T.DomainModel],
        familyRecordName: String?,
        logLabel: String
    ) async -> Bool {
        if let familyRecordName {
            let existing: [T]
            do { existing = try modelContext.fetch(T.fetchDescriptor(familyRecordName: familyRecordName)) } catch {
                logger.error("Failed to fetch existing \(T.self, privacy: .private) for \(logLabel, privacy: .public): \(error, privacy: .private)")
                return false
            }
            let byName = Dictionary(existing.map { ($0.recordName, $0) }, uniquingKeysWith: { first, _ in first })
            for item in items {
                let name = item.id.recordName
                if let target = byName[name] {
                    if target.familyRecordName != familyRecordName,
                       !target.familyRecordName.isEmpty
                    {
                        logger.warning(
                            """
                            BackgroundCacheActor \(logLabel, privacy: .public) target mismatch for \
                            \(name, privacy: .private): expected \
                            \(familyRecordName, privacy: .private), found \
                            \(target.familyRecordName, privacy: .private)
                            """
                        )
                        continue
                    }
                    target.update(from: item, isServerSync: true)
                } else {
                    let newRow = T(from: item)
                    if newRow.familyRecordName != familyRecordName,
                       !newRow.familyRecordName.isEmpty
                    {
                        logger.warning(
                            """
                            BackgroundCacheActor \(logLabel, privacy: .public) new row mismatch for \
                            \(name, privacy: .private): expected \
                            \(familyRecordName, privacy: .private), found \
                            \(newRow.familyRecordName, privacy: .private)
                            """
                        )
                        continue
                    }
                    modelContext.insert(newRow)
                }
            }
            return true
        }
        // Nil family — families themselves are unscoped; other types group by
        // their own family scope and recurse per family.
        if T.self == FamilyCache.self {
            let existing: [T]
            do { existing = try modelContext.fetch(T.fetchDescriptor(familyRecordName: nil)) } catch {
                logger.error("Failed to fetch existing \(T.self, privacy: .private) for \(logLabel, privacy: .public): \(error, privacy: .private)")
                return false
            }
            let byName = Dictionary(existing.map { ($0.recordName, $0) }, uniquingKeysWith: { first, _ in first })
            for item in items {
                let name = item.id.recordName
                if let target = byName[name] {
                    target.update(from: item, isServerSync: true)
                } else {
                    modelContext.insert(T(from: item))
                }
            }
            return true
        }
        let grouped = Dictionary(grouping: items) { T(from: $0).familyRecordName }
        var success = true
        for (family, group) in grouped {
            success = await performUpsert(T.self, group, familyRecordName: family.isEmpty ? nil : family, logLabel: logLabel) && success
        }
        return success
    }

    /// Deferred variant of batchUpsert that mutates the actor's ModelContext
    /// without saving, allowing the caller to coalesce multiple type batches
    /// into a single saveContext() at the transaction boundary.
    private func batchUpsertWithoutSave<T: CacheMergeable>(_: T.Type, _ items: [T.DomainModel], familyRecordName: String?) async -> Bool {
        await performUpsert(T.self, items, familyRecordName: familyRecordName, logLabel: "batchUpsertWithoutSave")
    }

    private func reconcileRewardEventsWithoutSave(_ events: [RewardEvent]) async -> Bool {
        for event in events {
            let completionName = event.questCompletion.recordID.recordName
            let familyName = event.family.recordID.recordName
            do {
                let descriptor = FetchDescriptor<QuestCompletionCache>(predicate: #Predicate { $0.recordName == completionName && $0.familyRecordName == familyName })
                if let match = try modelContext.fetch(descriptor).first {
                    applyRewardEvent(event, to: match)
                }
            } catch {
                logger.error("Failed to query QuestCompletionCache for RewardEvent reconciliation: \(error, privacy: .private)")
                return false
            }
        }
        return true
    }

    private func reconcileStoredRewardEventsWithoutSave(for completions: [QuestCompletion]) async -> Bool {
        for completion in completions {
            let familyName = completion.family.recordID.recordName
            let completionRecordName = completion.id.recordName
            let eventDescriptor =
                FetchDescriptor<RewardEventCache>(predicate: #Predicate { $0.familyRecordName == familyName && $0.questCompletionRecordName == completionRecordName })
            do {
                let events = try modelContext.fetch(eventDescriptor)
                let completionDescriptor =
                    FetchDescriptor<QuestCompletionCache>(predicate: #Predicate { $0.recordName == completionRecordName && $0.familyRecordName == familyName })
                if let cachedCompletion = try modelContext.fetch(completionDescriptor).first {
                    for event in events {
                        applyRewardEvent(event.toRewardEvent(zoneID: completion.id.zoneID), to: cachedCompletion)
                    }
                }
            } catch {
                logger.error("Failed to reconcile stored RewardEvent for completion \(completion.id.recordName, privacy: .private): \(error, privacy: .private)")
                return false
            }
        }
        return true
    }

    /// Legacy single-type paths retain their own save for backward compat.
    private func reconcileRewardEvents(_ events: [RewardEvent]) async -> Bool {
        let ok = await reconcileRewardEventsWithoutSave(events)
        guard ok else { return false }
        return saveContext()
    }

    private func reconcileStoredRewardEvents(for completions: [QuestCompletion]) async -> Bool {
        let ok = await reconcileStoredRewardEventsWithoutSave(for: completions)
        guard ok else { return false }
        return saveContext()
    }

    private func applyRewardEvent(_ event: RewardEvent, to completion: QuestCompletionCache) {
        guard let credited = completion.xpCredited else {
            completion.xpCredited = event.xpAmount
            logger
                .info(
                    "Hydrated xpCredited (\(event.xpAmount)) on completion \(completion.recordName, privacy: .private) from RewardEvent \(event.id.recordName, privacy: .private)"
                )
            return
        }
        guard credited < event.xpAmount else { return }
        completion.xpCredited = event.xpAmount
        logger.info("Hydrated xpCredited (\(event.xpAmount)) on completion \(completion.recordName, privacy: .private) from RewardEvent \(event.id.recordName, privacy: .private)")
    }

    // MARK: - Purges (public API preserved as thin wrappers)

    private func validatedFamilyScope(_ familyRecordName: String?) -> String? {
        guard let familyRecordName, !familyRecordName.isEmpty else {
            logger.warning("Purge skipped: familyRecordName is required, got nil/empty scope")
            return nil
        }
        return familyRecordName
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

    func purgeMissingLedgerEntries(validRecordNames: Set<String>, familyRecordName: String? = nil) async {
        await purgeMissing(LedgerEntryCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
    }

    func purgeMissingAllowancePeriods(validRecordNames: Set<String>, familyRecordName: String? = nil) async {
        await purgeMissing(AllowancePeriodCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
    }

    func purgeMissingAchievements(validRecordNames: Set<String>, familyRecordName: String? = nil) async {
        await purgeMissing(AchievementCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
    }

    func purgeMissingProfileAchievements(validRecordNames: Set<String>, familyRecordName: String? = nil) async {
        await purgeMissing(ProfileAchievementCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
    }

    func purgeMissingFamilies(validRecordNames: Set<String>) async {
        await purgeMissing(FamilyCache.self, validRecordNames: validRecordNames, familyRecordName: nil)
    }

    func purgeMissingNotificationPreferences(validRecordNames: Set<String>, familyRecordName: String? = nil) async {
        await purgeMissing(NotificationPreferenceCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
    }

    func purgeMissingGemLedgers(validRecordNames: Set<String>, familyRecordName: String? = nil) async {
        await purgeMissing(GemLedgerCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
    }

    func purgeMissingRewardEvents(validRecordNames: Set<String>, familyRecordName: String? = nil) async {
        await purgeMissing(RewardEventCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
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

    func deleteRecord(identity: ScopedRecordIdentity, type: CachedRecordType) async {
        switch type {
        case .profile: await deleteRecordByIdentity(ProfileCache.self, identity: identity)
        case .family: await deleteRecordByIdentity(FamilyCache.self, identity: identity)
        case .quest: await deleteRecordByIdentity(QuestCache.self, identity: identity)
        case .questTemplate: await deleteRecordByIdentity(QuestTemplateCache.self, identity: identity)
        case .questCompletion: await deleteRecordByIdentity(QuestCompletionCache.self, identity: identity)
        case .ledgerEntry: await deleteRecordByIdentity(LedgerEntryCache.self, identity: identity)
        case .allowancePeriod: await deleteRecordByIdentity(AllowancePeriodCache.self, identity: identity)
        case .achievement: await deleteRecordByIdentity(AchievementCache.self, identity: identity)
        case .profileAchievement: await deleteRecordByIdentity(ProfileAchievementCache.self, identity: identity)
        case .notificationPreference: await deleteRecordByIdentity(NotificationPreferenceCache.self, identity: identity)
        case .gemLedger: await deleteRecordByIdentity(GemLedgerCache.self, identity: identity)
        case .rewardEvent: await deleteRecordByIdentity(RewardEventCache.self, identity: identity)
        }
        saveContext()
    }

    private func deleteRecordByIdentity<T: CacheMergeable>(_: T.Type, identity: ScopedRecordIdentity) async {
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
                let activeZone: CKRecordZone.ID? = await MainActor.run {
                    let defaults = UserDefaults.standard
                    guard let zoneName = defaults.string(forKey: "session_familyZoneName"),
                          let ownerName = defaults.string(forKey: "session_familyZoneOwnerName") else { return nil }
                    return CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName)
                }
                let isActiveZone = activeZone.map { $0 == identity.zoneID } ?? false
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

    /// Batch variant of the system-field refresh: applies every descriptor to
    /// its cache row and commits all of them under one context save. A
    /// multi-record save round-trip would otherwise pay one fetch+save per
    /// record, stalling the actor for the whole pass.
    ///
    /// Refreshes ONLY the server-owned system fields (`changeTag`,
    /// `encodedSystemFields`) after CKSyncEngine confirms a successful save.
    /// Full-record parsing and merging must stay on the fetch path: rewriting
    /// whole records here would clobber local optimistic state that may
    /// legitimately have diverged while the save was in flight.
    ///
    /// The outcome distinguishes a legal no-op (every row absent — records may
    /// have been deleted locally mid-flight) from an actual context-save
    /// failure, so callers can keep sync-completion accounting honest without
    /// masking real cache-write failures behind silence.
    @discardableResult
    func updateSystemFields(_ refreshes: [SystemFieldRefresh], familyRecordName: String) async -> SystemFieldRefreshOutcome {
        guard !refreshes.isEmpty else { return .noMatches }
        guard await applySystemFieldRefreshes(refreshes, familyRecordName: familyRecordName) else {
            return .noMatches
        }
        return saveContext() ? .updated : .saveFailed
    }

    private func applySystemFieldRefreshes(_ refreshes: [SystemFieldRefresh], familyRecordName: String) async -> Bool {
        var didUpdate = false
        for refresh in refreshes {
            let updated: Bool = switch refresh.type {
            case .profile:
                await updateSystemFields(
                    ProfileCache.self,
                    recordName: refresh.recordName,
                    familyRecordName: familyRecordName,
                    changeTag: refresh.changeTag,
                    encodedSystemFields: refresh.encodedSystemFields
                )
            case .family:
                await updateSystemFields(
                    FamilyCache.self,
                    recordName: refresh.recordName,
                    familyRecordName: familyRecordName,
                    changeTag: refresh.changeTag,
                    encodedSystemFields: refresh.encodedSystemFields
                )
            case .quest:
                await updateSystemFields(
                    QuestCache.self,
                    recordName: refresh.recordName,
                    familyRecordName: familyRecordName,
                    changeTag: refresh.changeTag,
                    encodedSystemFields: refresh.encodedSystemFields
                )
            case .questTemplate:
                await updateSystemFields(
                    QuestTemplateCache.self,
                    recordName: refresh.recordName,
                    familyRecordName: familyRecordName,
                    changeTag: refresh.changeTag,
                    encodedSystemFields: refresh.encodedSystemFields
                )
            case .questCompletion:
                await updateSystemFields(
                    QuestCompletionCache.self,
                    recordName: refresh.recordName,
                    familyRecordName: familyRecordName,
                    changeTag: refresh.changeTag,
                    encodedSystemFields: refresh.encodedSystemFields
                )
            case .ledgerEntry:
                await updateSystemFields(
                    LedgerEntryCache.self,
                    recordName: refresh.recordName,
                    familyRecordName: familyRecordName,
                    changeTag: refresh.changeTag,
                    encodedSystemFields: refresh.encodedSystemFields
                )
            case .allowancePeriod:
                await updateSystemFields(
                    AllowancePeriodCache.self,
                    recordName: refresh.recordName,
                    familyRecordName: familyRecordName,
                    changeTag: refresh.changeTag,
                    encodedSystemFields: refresh.encodedSystemFields
                )
            case .achievement:
                await updateSystemFields(
                    AchievementCache.self,
                    recordName: refresh.recordName,
                    familyRecordName: familyRecordName,
                    changeTag: refresh.changeTag,
                    encodedSystemFields: refresh.encodedSystemFields
                )
            case .profileAchievement:
                await updateSystemFields(
                    ProfileAchievementCache.self,
                    recordName: refresh.recordName,
                    familyRecordName: familyRecordName,
                    changeTag: refresh.changeTag,
                    encodedSystemFields: refresh.encodedSystemFields
                )
            case .notificationPreference:
                await updateSystemFields(
                    NotificationPreferenceCache.self,
                    recordName: refresh.recordName,
                    familyRecordName: familyRecordName,
                    changeTag: refresh.changeTag,
                    encodedSystemFields: refresh.encodedSystemFields
                )
            case .gemLedger:
                await updateSystemFields(
                    GemLedgerCache.self,
                    recordName: refresh.recordName,
                    familyRecordName: familyRecordName,
                    changeTag: refresh.changeTag,
                    encodedSystemFields: refresh.encodedSystemFields
                )
            case .rewardEvent:
                await updateSystemFields(
                    RewardEventCache.self,
                    recordName: refresh.recordName,
                    familyRecordName: familyRecordName,
                    changeTag: refresh.changeTag,
                    encodedSystemFields: refresh.encodedSystemFields
                )
            }
            if updated {
                didUpdate = true
            }
        }
        // Absent rows are legal mid-flight deletions, not write failures — a
        // pass that touched nothing must not pay for a context save or report
        // itself as a completed write.
        return didUpdate
    }

    private func updateSystemFields<T: SystemFieldUpdatable>(
        _: T.Type,
        recordName: String,
        familyRecordName: String,
        changeTag: String?,
        encodedSystemFields: Data?
    ) async -> Bool {
        let match: T?
        do { match = try modelContext.fetch(T.fetchDescriptor(recordName: recordName)).first } catch {
            logger.error("Failed to fetch \(T.self, privacy: .private) for system-field refresh (\(recordName, privacy: .private)): \(error, privacy: .private)")
            match = nil
        }
        guard let match else {
            // Absence is legal: the row may have been deleted locally mid-flight
            // while this save was outstanding.
            logger.debug("Skipping system-field refresh; no cached row for \(recordName, privacy: .private)")
            return false
        }
        guard match.familyRecordName == familyRecordName else {
            logger.debug(
                """
                Skipping system-field refresh for \(recordName, privacy: .private): \
                expected family \(familyRecordName, privacy: .private), found \
                \(match.familyRecordName, privacy: .private)
                """
            )
            return false
        }
        match.changeTag = changeTag
        match.encodedSystemFields = encodedSystemFields
        return true
    }

    @discardableResult
    private func saveContext() -> Bool {
        do {
            try modelContext.save()
            return true
        } catch {
            logger.error("Failed to save background context: \(error, privacy: .private)")
            return false
        }
    }
}

/// Minimal protocol surface for refreshing server-owned system fields on a
/// cached row, so the generic refresh helper needs no per-type domain-model
/// merge scaffolding.
private protocol SystemFieldUpdatable: CacheMergeable {
    var changeTag: String? { get set }
    var encodedSystemFields: Data? { get set }
}

extension ProfileCache: SystemFieldUpdatable {}
extension FamilyCache: SystemFieldUpdatable {}
extension QuestCache: SystemFieldUpdatable {}
extension QuestTemplateCache: SystemFieldUpdatable {}
extension QuestCompletionCache: SystemFieldUpdatable {}
extension LedgerEntryCache: SystemFieldUpdatable {}
extension AllowancePeriodCache: SystemFieldUpdatable {}
extension AchievementCache: SystemFieldUpdatable {}
extension ProfileAchievementCache: SystemFieldUpdatable {}
extension NotificationPreferenceCache: SystemFieldUpdatable {}
extension GemLedgerCache: SystemFieldUpdatable {}
extension RewardEventCache: SystemFieldUpdatable {}
