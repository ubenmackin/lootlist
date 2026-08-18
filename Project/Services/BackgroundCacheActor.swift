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

    // MARK: - Generic batch helpers

    // changeTag is copied unconditionally — nil is a meaningful "no further tag" value that must propagate.

    /// Generic upsert shared by every `batchUpsert*` wrapper. Fetches existing
    /// rows via `T.fetchDescriptor`, keys them by `recordName`, then updates or
    /// inserts each item. The field-for-field merge lives in each type's
    /// `CacheMergeable.update(from:)` — explicit and type-safe, no reflection.
    @discardableResult
    private func batchUpsert<T: CacheMergeable>(
        _: T.Type,
        _ items: [T.DomainModel],
        familyRecordName: String?
    ) async -> Bool {
        let existing: [T]
        do {
            existing = try modelContext.fetch(T.fetchDescriptor(familyRecordName: familyRecordName))
        } catch {
            logger.error("Failed to fetch existing \(T.self, privacy: .public) for batchUpsert: \(error, privacy: .public)")
            return false
        }
        let byName = Dictionary(existing.map { ($0.recordName, $0) }, uniquingKeysWith: { first, _ in first })
        for item in items {
            let name = item.id.recordName
            if let target = byName[name] {
                if let familyRecordName, target.familyRecordName != familyRecordName {
                    logger.warning("BackgroundCacheActor batchUpsert target family mismatch for \(name): expected \(familyRecordName), found \(target.familyRecordName)")
                    continue
                }
                target.update(from: item, isServerSync: true)
            } else {
                let newRow = T(from: item)
                if let familyRecordName, newRow.familyRecordName != familyRecordName {
                    logger.warning("BackgroundCacheActor batchUpsert new row family mismatch for \(name): expected \(familyRecordName), found \(newRow.familyRecordName)")
                    continue
                }
                modelContext.insert(newRow)
            }
        }
        return saveContext()
    }

    /// Generic purge shared by every `purgeMissing*` wrapper. Deletes cached rows
    /// whose `recordName` is absent from `validRecordNames`. Snapshot-based: an
    /// optimistically upserted row may be reported missing; the author's
    /// post-save re-upsert reconciles it.
    private func purgeMissing<T: CacheMergeable>(
        _: T.Type,
        validRecordNames: Set<String>,
        familyRecordName: String?
    ) async {
        // Guard against an empty validRecordNames set: if the upstream query
        // threw or was cancelled, the caller passes an empty set. Purging on an
        // empty validRecordNames destroys valid local cached data.
        guard !validRecordNames.isEmpty else { return }

        let existing: [T]
        do {
            existing = try modelContext.fetch(T.fetchDescriptor(familyRecordName: familyRecordName))
        } catch {
            logger.error("Failed to fetch existing \(T.self, privacy: .public) for purgeMissing: \(error, privacy: .public)")
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
        if let familyRecordName {
            return await batchUpsert(QuestCache.self, quests, familyRecordName: familyRecordName)
        }
        let grouped = Dictionary(grouping: quests, by: { $0.family.recordID.recordName })
        var success = true
        for (family, familyQuests) in grouped {
            success = await batchUpsert(QuestCache.self, familyQuests, familyRecordName: family) && success
        }
        return success
    }

    /// Backfills `name` on any Quest in `quests` whose `name` is nil by
    /// reading the authoritative template record from CloudKit. Runs in the
    /// background actor so the per-template await does not contend with the
    /// cache-hit read path. Returns a new array with stamped names where
    /// available; callers must use the returned array for subsequent upsert.
    func backfillQuestNames(_ quests: [Quest], cloudKit: any CloudKitServiceProtocol) async -> [Quest] {
        let nameless = quests.filter { $0.name == nil }
        guard !nameless.isEmpty else { return quests }
        let recordNames = Set(nameless.map(\.template.recordID))
        var templatesByID: [CKRecord.ID: QuestTemplate] = [:]
        for recordID in recordNames {
            do {
                let template = try await cloudKit.fetch(QuestTemplate.self, id: recordID)
                templatesByID[recordID] = template
            } catch {
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
        if let familyRecordName {
            return await batchUpsert(ProfileCache.self, profiles, familyRecordName: familyRecordName)
        }
        let grouped = Dictionary(grouping: profiles, by: { $0.family.recordID.recordName })
        var success = true
        for (family, familyProfiles) in grouped {
            success = await batchUpsert(ProfileCache.self, familyProfiles, familyRecordName: family) && success
        }
        return success
    }

    @discardableResult
    func batchUpsertQuestCompletions(_ completions: [QuestCompletion], familyRecordName: String? = nil) async -> Bool {
        if let familyRecordName {
            return await batchUpsert(QuestCompletionCache.self, completions, familyRecordName: familyRecordName)
        }
        let grouped = Dictionary(grouping: completions, by: { $0.family.recordID.recordName })
        var success = true
        for (family, familyCompletions) in grouped {
            success = await batchUpsert(QuestCompletionCache.self, familyCompletions, familyRecordName: family) && success
        }
        return success
    }

    @discardableResult
    func batchUpsertQuestTemplates(_ templates: [QuestTemplate], familyRecordName: String? = nil) async -> Bool {
        if let familyRecordName {
            return await batchUpsert(QuestTemplateCache.self, templates, familyRecordName: familyRecordName)
        }
        let grouped = Dictionary(grouping: templates, by: { $0.family.recordID.recordName })
        var success = true
        for (family, familyTemplates) in grouped {
            success = await batchUpsert(QuestTemplateCache.self, familyTemplates, familyRecordName: family) && success
        }
        return success
    }

    @discardableResult
    func batchUpsertLedgerEntries(_ entries: [LedgerEntry], familyRecordName: String? = nil) async -> Bool {
        if let familyRecordName {
            return await batchUpsert(LedgerEntryCache.self, entries, familyRecordName: familyRecordName)
        }
        let grouped = Dictionary(grouping: entries, by: { $0.family.recordID.recordName })
        var success = true
        for (family, familyEntries) in grouped {
            success = await batchUpsert(LedgerEntryCache.self, familyEntries, familyRecordName: family) && success
        }
        return success
    }

    @discardableResult
    func batchUpsertAllowancePeriods(_ periods: [AllowancePeriod], familyRecordName: String? = nil) async -> Bool {
        if let familyRecordName {
            return await batchUpsert(AllowancePeriodCache.self, periods, familyRecordName: familyRecordName)
        }
        let grouped = Dictionary(grouping: periods, by: { $0.family.recordID.recordName })
        var success = true
        for (family, familyPeriods) in grouped {
            success = await batchUpsert(AllowancePeriodCache.self, familyPeriods, familyRecordName: family) && success
        }
        return success
    }

    @discardableResult
    func batchUpsertAchievements(_ achievements: [Achievement], familyRecordName: String? = nil) async -> Bool {
        if let familyRecordName {
            return await batchUpsert(AchievementCache.self, achievements, familyRecordName: familyRecordName)
        }
        let grouped = Dictionary(grouping: achievements, by: { $0.family.recordID.recordName })
        var success = true
        for (family, familyAchievements) in grouped {
            success = await batchUpsert(AchievementCache.self, familyAchievements, familyRecordName: family) && success
        }
        return success
    }

    @discardableResult
    func batchUpsertProfileAchievements(_ pas: [ProfileAchievement], familyRecordName: String? = nil) async -> Bool {
        if let familyRecordName {
            return await batchUpsert(ProfileAchievementCache.self, pas, familyRecordName: familyRecordName)
        }
        let grouped = Dictionary(grouping: pas, by: { $0.family.recordID.recordName })
        var success = true
        for (family, familyPAs) in grouped {
            success = await batchUpsert(ProfileAchievementCache.self, familyPAs, familyRecordName: family) && success
        }
        return success
    }

    @discardableResult
    func batchUpsertFamilies(_ families: [Family]) async -> Bool {
        await batchUpsert(FamilyCache.self, families, familyRecordName: nil)
    }

    @discardableResult
    func batchUpsertNotificationPreferences(_ prefs: [NotificationPreference], familyRecordName: String? = nil) async -> Bool {
        if let familyRecordName {
            return await batchUpsert(NotificationPreferenceCache.self, prefs, familyRecordName: familyRecordName)
        }
        let grouped = Dictionary(grouping: prefs, by: { $0.family.recordID.recordName })
        var success = true
        for (family, familyPrefs) in grouped {
            success = await batchUpsert(NotificationPreferenceCache.self, familyPrefs, familyRecordName: family) && success
        }
        return success
    }

    @discardableResult
    func batchUpsertGemLedgers(_ entries: [GemLedger], familyRecordName _: String? = nil) async -> Bool {
        let grouped = Dictionary(grouping: entries) { $0.family.recordID.recordName }
        var success = true
        for (family, familyEntries) in grouped {
            success = await batchUpsert(GemLedgerCache.self, familyEntries, familyRecordName: family) && success
        }
        return success
    }

    @discardableResult
    func batchUpsertRewardEvents(_ events: [RewardEvent], familyRecordName: String? = nil) async -> Bool {
        if let familyRecordName {
            return await batchUpsert(RewardEventCache.self, events, familyRecordName: familyRecordName)
        }
        let grouped = Dictionary(grouping: events, by: { $0.family.recordID.recordName })
        var success = true
        for (family, familyEvents) in grouped {
            success = await batchUpsert(RewardEventCache.self, familyEvents, familyRecordName: family) && success
        }
        return success
    }

    private struct ParsedBatch {
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

    @discardableResult
    func batchUpsertParsedRecords(_ records: [ParsedRecord]) async -> Bool {
        var batch = ParsedBatch()
        for record in records {
            batch.append(record)
        }
        return await commitParsedBatch(batch)
    }

    private func commitParsedBatch(_ batch: ParsedBatch) async -> Bool {
        let coreSuccess = await commitCoreEntities(batch)
        let secondarySuccess = await commitSecondaryEntities(batch)
        return coreSuccess && secondarySuccess
    }

    private func commitCoreEntities(_ batch: ParsedBatch) async -> Bool {
        var success = true
        if !batch.families.isEmpty {
            success = await batchUpsertFamilies(batch.families) && success
        }
        if !batch.profiles.isEmpty {
            success = await batchUpsertProfiles(batch.profiles) && success
        }
        if !batch.quests.isEmpty {
            success = await batchUpsertQuests(batch.quests) && success
        }
        if !batch.templates.isEmpty {
            success = await batchUpsertQuestTemplates(batch.templates) && success
        }
        if !batch.completions.isEmpty {
            success = await batchUpsertQuestCompletions(batch.completions) && success
            success = await reconcileStoredRewardEvents(for: batch.completions) && success
        }
        return success
    }

    private func commitSecondaryEntities(_ batch: ParsedBatch) async -> Bool {
        var success = true
        if !batch.ledgerEntries.isEmpty {
            success = await batchUpsertLedgerEntries(batch.ledgerEntries) && success
        }
        if !batch.periods.isEmpty {
            success = await batchUpsertAllowancePeriods(batch.periods) && success
        }
        if !batch.achievements.isEmpty {
            success = await batchUpsertAchievements(batch.achievements) && success
        }
        if !batch.profileAchievements.isEmpty {
            success = await batchUpsertProfileAchievements(batch.profileAchievements) && success
        }
        if !batch.notificationPrefs.isEmpty {
            success = await batchUpsertNotificationPreferences(batch.notificationPrefs) && success
        }
        if !batch.gemLedgers.isEmpty {
            success = await batchUpsertGemLedgers(batch.gemLedgers) && success
        }
        if !batch.rewardEvents.isEmpty {
            success = await batchUpsertRewardEvents(batch.rewardEvents) && success
            success = await reconcileRewardEvents(batch.rewardEvents) && success
        }
        return success
    }

    private func reconcileRewardEvents(_ events: [RewardEvent]) async -> Bool {
        for event in events {
            let completionName = event.questCompletion.recordID.recordName
            let familyName = event.family.recordID.recordName
            do {
                let descriptor = FetchDescriptor<QuestCompletionCache>(
                    predicate: #Predicate { $0.recordName == completionName && $0.familyRecordName == familyName }
                )
                if let match = try modelContext.fetch(descriptor).first {
                    applyRewardEvent(event, to: match)
                }
            } catch {
                logger.error("Failed to query QuestCompletionCache for RewardEvent reconciliation: \(error, privacy: .public)")
                return false
            }
        }
        return saveContext()
    }

    private func reconcileStoredRewardEvents(for completions: [QuestCompletion]) async -> Bool {
        for completion in completions {
            let familyName = completion.family.recordID.recordName
            let completionRecordName = completion.id.recordName
            let eventDescriptor = FetchDescriptor<RewardEventCache>(
                predicate: #Predicate {
                    $0.familyRecordName == familyName && $0.questCompletionRecordName == completionRecordName
                }
            )
            do {
                let events = try modelContext.fetch(eventDescriptor)
                let completionDescriptor = FetchDescriptor<QuestCompletionCache>(
                    predicate: #Predicate {
                        $0.recordName == completionRecordName && $0.familyRecordName == familyName
                    }
                )
                if let cachedCompletion = try modelContext.fetch(completionDescriptor).first {
                    for event in events {
                        applyRewardEvent(event.toRewardEvent(zoneID: completion.id.zoneID), to: cachedCompletion)
                    }
                }
            } catch {
                logger.error("Failed to reconcile stored RewardEvent for completion \(completion.id.recordName, privacy: .private): \(error, privacy: .public)")
                return false
            }
        }
        return saveContext()
    }

    private func applyRewardEvent(_ event: RewardEvent, to completion: QuestCompletionCache) {
        guard completion.xpCredited == nil || (completion.xpCredited ?? 0) < event.xpAmount else { return }
        completion.xpCredited = event.xpAmount
        logger.info("Hydrated xpCredited (\(event.xpAmount)) on completion \(completion.recordName, privacy: .private) from RewardEvent \(event.id.recordName, privacy: .private)")
    }

    // MARK: - Purges (public API preserved as thin wrappers)

    /// Guards the purge path against a nil or empty `familyRecordName`.
    /// A purge without a concrete family scope could delete another family's
    /// cached rows — a cross-family data-loss hazard. `FamilyCache` is exempt:
    /// it is the root record, never family-scoped, and is always purged globally.
    /// Returns the validated non-empty scope, or nil to short-circuit the purge.
    private func validatedFamilyScope(_ familyRecordName: String?) -> String? {
        guard let familyRecordName, !familyRecordName.isEmpty else {
            logger.warning("Purge skipped: familyRecordName is required, got nil/empty scope")
            return nil
        }
        return familyRecordName
    }

    func purgeMissingQuests(validRecordNames: Set<String>, familyRecordName: String? = nil) async {
        guard let familyRecordName = validatedFamilyScope(familyRecordName) else { return }
        await purgeMissing(QuestCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
    }

    func purgeMissingProfiles(validRecordNames: Set<String>, familyRecordName: String? = nil) async {
        guard let familyRecordName = validatedFamilyScope(familyRecordName) else { return }
        await purgeMissing(ProfileCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
    }

    func purgeMissingQuestCompletions(validRecordNames: Set<String>, familyRecordName: String? = nil) async {
        guard let familyRecordName = validatedFamilyScope(familyRecordName) else { return }
        await purgeMissing(QuestCompletionCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
    }

    func purgeMissingQuestTemplates(validRecordNames: Set<String>, familyRecordName: String? = nil) async {
        guard let familyRecordName = validatedFamilyScope(familyRecordName) else { return }
        await purgeMissing(QuestTemplateCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
    }

    func purgeMissingLedgerEntries(validRecordNames: Set<String>, familyRecordName: String? = nil) async {
        guard let familyRecordName = validatedFamilyScope(familyRecordName) else { return }
        await purgeMissing(LedgerEntryCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
    }

    func purgeMissingAllowancePeriods(validRecordNames: Set<String>, familyRecordName: String? = nil) async {
        guard let familyRecordName = validatedFamilyScope(familyRecordName) else { return }
        await purgeMissing(AllowancePeriodCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
    }

    func purgeMissingAchievements(validRecordNames: Set<String>, familyRecordName: String? = nil) async {
        guard let familyRecordName = validatedFamilyScope(familyRecordName) else { return }
        await purgeMissing(AchievementCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
    }

    func purgeMissingProfileAchievements(validRecordNames: Set<String>, familyRecordName: String? = nil) async {
        guard let familyRecordName = validatedFamilyScope(familyRecordName) else { return }
        await purgeMissing(ProfileAchievementCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
    }

    func purgeMissingFamilies(validRecordNames: Set<String>) async {
        await purgeMissing(FamilyCache.self, validRecordNames: validRecordNames, familyRecordName: nil)
    }

    func purgeMissingNotificationPreferences(validRecordNames: Set<String>, familyRecordName: String? = nil) async {
        guard let familyRecordName = validatedFamilyScope(familyRecordName) else { return }
        await purgeMissing(NotificationPreferenceCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
    }

    func purgeMissingGemLedgers(validRecordNames: Set<String>, familyRecordName: String? = nil) async {
        guard let familyRecordName = validatedFamilyScope(familyRecordName) else { return }
        await purgeMissing(GemLedgerCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
    }

    func purgeMissingRewardEvents(validRecordNames: Set<String>, familyRecordName: String? = nil) async {
        guard let familyRecordName = validatedFamilyScope(familyRecordName) else { return }
        await purgeMissing(RewardEventCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
    }

    /// Deletes the `FamilyCache` matching `recordName` and all child caches
    /// scoped to that family, mirroring `CacheService.purgeFamily` on the
    /// background context. Used when `CKSyncEngine` reports a whole zone
    /// (family) deleted server-side, so stale rows cannot survive the sync.
    func purgeFamily(recordName: String) async {
        if let match = try? modelContext.fetch(FamilyCache.fetchDescriptor(recordName: recordName)).first {
            modelContext.delete(match)
        }
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

    /// Deletes every cached row of `T` whose `familyRecordName` matches.
    private func purgeFamilyRows<T: CacheMergeable>(_: T.Type, familyRecordName: String) async {
        let existing: [T]
        do {
            existing = try modelContext.fetch(T.fetchDescriptor(familyRecordName: familyRecordName))
        } catch {
            logger.error("Failed to fetch \(T.self, privacy: .public) for family purge: \(error, privacy: .public)")
            existing = []
        }
        for cached in existing {
            modelContext.delete(cached)
        }
    }

    /// One-time migration: backfills `targetCount = 1` for legacy rows where
    /// the value is nil/zero/unset. Idempotent — positive values are untouched.
    func backfillTargetCountGlobally() {
        // QuestCache — iterate by recordName (global, not per-family).
        let quests: [QuestCache]
        do {
            quests = try modelContext.fetch(FetchDescriptor<QuestCache>())
        } catch {
            logger.error("Failed to fetch QuestCache for backfill: \(error, privacy: .public)")
            quests = []
        }
        for quest in quests where quest.targetCount <= 0 {
            quest.targetCount = 1
        }

        // QuestTemplateCache — same global-by-recordName iteration.
        let templates: [QuestTemplateCache]
        do {
            templates = try modelContext.fetch(FetchDescriptor<QuestTemplateCache>())
        } catch {
            logger.error("Failed to fetch QuestTemplateCache for backfill: \(error, privacy: .public)")
            templates = []
        }
        for template in templates where template.targetCount <= 0 {
            template.targetCount = 1
        }

        saveContext()

        // Defense-in-depth: surface any rows that still carry a non-positive targetCount
        // after the backfill sweep. The runtime GoldCalculation.isFullyCompleted guard
        // tolerates a residual zero, but surfacing it here narrows the diagnostic window.
        let zeroQuests: [QuestCache]
        do {
            zeroQuests = try modelContext.fetch(FetchDescriptor<QuestCache>(predicate: #Predicate { $0.targetCount <= 0 }))
        } catch {
            logger.error("Failed to fetch zero-target QuestCache post-backfill: \(error, privacy: .public)")
            zeroQuests = []
        }
        for quest in zeroQuests {
            logger.warning("QuestCache targetCount stuck at zero post-backfill: \(quest.recordName, privacy: .private)")
        }

        let zeroTemplates: [QuestTemplateCache]
        do {
            zeroTemplates = try modelContext.fetch(FetchDescriptor<QuestTemplateCache>(predicate: #Predicate { $0.targetCount <= 0 }))
        } catch {
            logger.error("Failed to fetch zero-target QuestTemplateCache post-backfill: \(error, privacy: .public)")
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

    private func deleteRecordByIdentity<T: CacheMergeable>(
        _: T.Type,
        identity: ScopedRecordIdentity
    ) async {
        let recordName = identity.recordID.recordName
        let match: T?
        do {
            match = try modelContext.fetch(T.fetchDescriptor(recordName: recordName)).first
        } catch {
            logger.error("Failed to fetch \(T.self, privacy: .public) for record deletion (\(recordName, privacy: .private)): \(error, privacy: .public)")
            match = nil
        }
        if let match {
            if let expectedFamily = identity.familyRecordName, let scoped = match as? any FamilyScopedCache {
                guard scoped.familyRecordName == expectedFamily else {
                    logger.warning("BackgroundCacheActor deletion aborted for \(recordName): expected family \(expectedFamily), found \(scoped.familyRecordName)")
                    return
                }
            }
            if let scoped = match as? any FamilyScopedCache {
                if let sourceZone = scoped.sourceZoneName,
                   identity.zoneID.zoneName != CKRecordZone.default().zoneID.zoneName,
                   sourceZone != identity.zoneID.zoneName
                {
                    logger.warning("BackgroundCacheActor deletion aborted for \(recordName): expected zone \(identity.zoneID.zoneName), found \(sourceZone)")
                    return
                }
            }
            modelContext.delete(match)
        }
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
