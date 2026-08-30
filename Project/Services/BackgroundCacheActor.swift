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
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "BackgroundCacheActor")
    let mutationQueue = SerialMutationQueue()

    /// Creates the background cache actor off-main to avoid main-thread affinity.
    static func makeBackgroundWriter(for container: ModelContainer) async -> BackgroundCacheActor {
        await Task.detached(priority: .userInitiated) {
            #if DEBUG
                if !TestEnvironment.isRunningUnitOrUITests {
                    assert(!Thread.isMainThread, "BackgroundCacheActor creation must run off the main thread")
                }
            #endif
            return BackgroundCacheActor(container: container)
        }.value
    }

    init(container: ModelContainer) {
        #if DEBUG
            // In-memory test stores create the actor synchronously for deterministic seeding;
            // persistent stores must be created off-main via makeBackgroundWriter to avoid affinity.
            if !TestEnvironment.isRunningUnitOrUITests {
                assert(!Thread.isMainThread, "BackgroundCacheActor init must run off the main thread to avoid main-thread affinity")
            }
        #endif
        modelContainer = container
        let modelContext = ModelContext(container)
        modelContext.autosaveEnabled = false
        modelExecutor = DefaultSerialModelExecutor(modelContext: modelContext)
    }

    // MARK: - Generic batch helpers

    @discardableResult
    private func batchUpsert<T: CacheMergeable & CacheSystemFields>(
        _: T.Type,
        _ items: [T.DomainModel],
        familyRecordName: String?
    ) async -> Bool where T.DomainModel: DomainSystemFields {
        let ok = await performUpsert(T.self, items, familyRecordName: familyRecordName, logLabel: "batchUpsert")
        guard ok else { return false }
        return saveContext()
    }

    // purgeMissing helpers moved to BackgroundCacheActor+Maintenance.swift

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

    // MARK: - Domain-model upserts

    /// Single-writer mirror of the main-actor upsert surface. Each family scope commits as its own unit —
    /// one merge pass followed by one save — so a failed save for one family never rolls into another
    func upsertDomainModels<M: CacheMergeable & CacheSystemFields>(
        _ items: [M.DomainModel],
        type _: M.Type,
        familyRecordName: String?,
        isServerSync: Bool
    ) async where M.DomainModel: DomainSystemFields {
        guard !items.isEmpty else { return }
        if let familyRecordName {
            _ = await performUpsert(M.self, items, familyRecordName: familyRecordName, isServerSync: isServerSync, logLabel: "upsertDomainModels")
            saveContext()
            return
        }
        // Families are unscoped roots; every other type splits by its own
        // family scope so each group commits independently.
        if M.self == FamilyCache.self {
            _ = await performUpsert(M.self, items, familyRecordName: nil, isServerSync: isServerSync, logLabel: "upsertDomainModels")
            saveContext()
            return
        }
        let grouped = Dictionary(grouping: items) { M(from: $0).familyRecordName }
        for (family, group) in grouped {
            _ = await performUpsert(M.self, group, familyRecordName: family.isEmpty ? nil : family, isServerSync: isServerSync, logLabel: "upsertDomainModels")
            saveContext()
        }
    }

    func upsertDomainModel<M: CacheMergeable & CacheSystemFields>(
        _ item: M.DomainModel,
        type: M.Type,
        familyRecordName: String?,
        isServerSync: Bool
    ) async where M.DomainModel: DomainSystemFields {
        await upsertDomainModels([item], type: type, familyRecordName: familyRecordName, isServerSync: isServerSync)
    }

    // MARK: - Atomic gem credit

    /// Delegates to shared helper so ledger/profile stay in one transaction and idempotency via
    /// deterministic ledger ID is enforced once.
    @discardableResult
    func atomicallyApplyGemCredit(ledger: GemLedger, profile: Profile) async -> Bool {
        guard sharedGemCreditPrepare(
            context: modelContext,
            ledger: ledger,
            profile: profile
        ) else {
            modelContext.rollback()
            return false
        }
        return saveContext()
    }

    /// Debit mirror of the main-actor path: balance and ledger row mutate in one pass and commit together
    /// so a failed save can never split a debited profile from its ledger entry.
    func applyGemDebit(profile: Profile, ledger: GemLedger) async {
        var success = true
        success = await performUpsert(ProfileCache.self, [profile], familyRecordName: nil, isServerSync: true, logLabel: "applyGemDebit") && success
        success = await performUpsert(GemLedgerCache.self, [ledger], familyRecordName: nil, isServerSync: true, logLabel: "applyGemDebit") && success
        guard success else {
            modelContext.rollback()
            return
        }
        saveContext()
    }

    /// Mirrors the main-actor argument labels so service call sites transfer
    /// unchanged onto the single-writer surface.
    @discardableResult
    func atomicallyApplyGemCredit(ledger: GemLedger, to profile: Profile) async -> Bool {
        await atomicallyApplyGemCredit(ledger: ledger, profile: profile)
    }

    @discardableResult
    func batchUpsertRewardEvents(_ events: [RewardEvent], familyRecordName: String? = nil) async -> Bool {
        await batchUpsert(RewardEventCache.self, events, familyRecordName: familyRecordName)
    }

    @discardableResult
    func batchUpsertGoals(_ goals: [Goal], familyRecordName: String? = nil) async -> Bool {
        await batchUpsert(GoalCache.self, goals, familyRecordName: familyRecordName)
    }

    /// Batch upserts ledger entries and goal completions in a single transaction ending with one
    /// `saveContext()`, so `contributeToBucket`'s N allocations + M completions coalesce into one
    @discardableResult
    func batchUpsertLedgerEntriesAndGoals(
        ledgerEntries: [LedgerEntry],
        goals: [Goal],
        familyRecordName: String? = nil
    ) async -> Bool {
        guard !ledgerEntries.isEmpty || !goals.isEmpty else { return true }
        // Local optimistic writes must not be treated as server sync; identical
        // changeTags on local rows carry real field deltas and must not be skipped.
        let isServerSync = false
        var success = true
        // WHY: single grouped helper avoids duplicate fan-out and family-mismatch
        // paths for ledger vs goal and keeps the domain family as grouping key
        // without instantiating a cache model.
        if !ledgerEntries.isEmpty {
            success = await upsertGroupedWithoutSave(
                LedgerEntryCache.self,
                ledgerEntries,
                familyRecordName: familyRecordName,
                isServerSync: isServerSync,
                familyKey: { $0.family.recordID.recordName }
            ) && success
        }
        if !goals.isEmpty {
            success = await upsertGroupedWithoutSave(
                GoalCache.self,
                goals,
                familyRecordName: familyRecordName,
                isServerSync: isServerSync,
                familyKey: { $0.family.recordID.recordName }
            ) && success
        }
        guard success else {
            modelContext.rollback()
            return false
        }
        return saveContext()
    }

    /// WHY: centralizes grouped-family fallback and batchUpsertWithoutSave fan-out
    /// so ledger and goal batches share one path instead of duplicating it.
    private func upsertGroupedWithoutSave<T: CacheMergeable & CacheSystemFields>(
        _: T.Type,
        _ items: [T.DomainModel],
        familyRecordName: String?,
        isServerSync: Bool,
        familyKey: (T.DomainModel) -> String
    ) async -> Bool where T.DomainModel: DomainSystemFields {
        if let familyRecordName {
            return await batchUpsertWithoutSave(
                T.self,
                items,
                familyRecordName: familyRecordName,
                isServerSync: isServerSync
            )
        }
        let grouped = Dictionary(grouping: items, by: familyKey)
        var success = true
        for (family, group) in grouped {
            success = await batchUpsertWithoutSave(
                T.self,
                group,
                familyRecordName: family.isEmpty ? nil : family,
                isServerSync: isServerSync
            ) && success
        }
        return success
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
        var goals: [Goal] = []

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
            case let .goal(item): goals.append(item)
            case .ignoredSystemRecord, .parseFailure: break
            }
        }
    }

    // Atomic batch ingestion committing all parsed records in a single saveContext transaction.

    @discardableResult
    func batchUpsertParsedRecords(_ records: [ParsedRecord]) async -> Bool {
        #if DEBUG
            if !TestEnvironment.isRunningUnitOrUITests {
                assert(!Thread.isMainThread, "BackgroundCacheActor batch must not run on the main thread")
            }
        #endif
        var batch = ParsedBatch()
        for record in records {
            batch.append(record)
        }
        let capturedBatch = batch
        return await mutationQueue.write {
            await self.commitParsedBatch(capturedBatch)
        }
    }

    /// Accounting for one reconciliation pass, letting callers observe parse
    /// and commit failures without this actor reaching into main-actor
    /// sync-pass state.
    struct ReconciliationOutcome: Sendable {
        var recordCount = 0
        var parseFailures = 0
        var commitSucceeded = false
    }

    /// Participant reconciliation: upserts snapshot and prunes missing rows in one transaction.
    @discardableResult
    func reconcileParticipantSet(
        records: [CKRecord],
        validRecordNamesByType: [CachedRecordType: Set<String>],
        familyRecordName: String,
        databaseScope: CKDatabase.Scope,
        zoneID: CKRecordZone.ID
    ) async -> ReconciliationOutcome? {
        #if DEBUG
            if !TestEnvironment.isRunningUnitOrUITests {
                assert(!Thread.isMainThread, "BackgroundCacheActor reconciliation must not run on the main thread")
            }
        #endif
        guard databaseScope == .shared else {
            logger.warning("Participant reconciliation skipped for non-shared scope", family: familyRecordName, zone: zoneID.zoneName)
            return nil
        }
        // Parsing stays on the main actor like every other ingestion path;
        // only Sendable parsed models continue into the gated commit.
        let parsedRecords = await MainActor.run {
            records.map { ParsedRecord.parse(record: $0) }
        }
        var parseFailures = 0
        var batch = ParsedBatch()
        for parsed in parsedRecords {
            if case .parseFailure = parsed {
                parseFailures += 1
            }
            batch.append(parsed)
        }
        if parseFailures > 0 {
            logger.warning("\(parseFailures) record(s) failed to parse during participant reconciliation", family: familyRecordName, zone: zoneID.zoneName)
        }
        let capturedBatch = batch
        let commitSucceeded = await mutationQueue.write {
            await self.commitParticipantReconciliation(
                capturedBatch,
                validRecordNamesByType: validRecordNamesByType,
                familyRecordName: familyRecordName,
                zoneID: zoneID
            )
        }
        return ReconciliationOutcome(
            recordCount: records.count,
            parseFailures: parseFailures,
            commitSucceeded: commitSucceeded
        )
    }

    /// Single-transaction variant of the parsed-batch commit followed by a deferred purge per provided
    /// type.
    private func commitParticipantReconciliation(
        _ batch: ParsedBatch,
        validRecordNamesByType: [CachedRecordType: Set<String>],
        familyRecordName: String,
        zoneID: CKRecordZone.ID
    ) async -> Bool {
        var success = true
        success = await commitCoreEntitiesDeferred(batch) && success
        success = await commitSecondaryEntitiesDeferred(batch) && success
        guard success else {
            logger.error("Participant reconciliation upsert failed", family: familyRecordName, zone: zoneID.zoneName)
            return false
        }
        for (type, validRecordNames) in validRecordNamesByType {
            await purgeMissingOfType(type, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
        }
        guard saveContext() else {
            logger.error("Participant reconciliation save failed", family: familyRecordName, zone: zoneID.zoneName)
            return false
        }
        return true
    }

    /// Accumulates all inserts/updates and saves the ModelContext exactly once.
    private func commitParsedBatch(_ batch: ParsedBatch) async -> Bool {
        #if DEBUG
            if !TestEnvironment.isRunningUnitOrUITests {
                assert(!Thread.isMainThread, "BackgroundCacheActor commit must not run on the main thread")
            }
        #endif
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
        if !batch.goals.isEmpty {
            success = await batchUpsertWithoutSave(GoalCache.self, batch.goals, familyRecordName: nil) && success
        }
        return success
    }

    /// Shared upsert core: mutates the actor's ModelContext without saving so callers decide when to commit
    /// — single-type paths save immediately, while multi-type batches coalesce into one saveContext() at
    private func performUpsert<T: CacheMergeable & CacheSystemFields>(
        _: T.Type,
        _ items: [T.DomainModel],
        familyRecordName: String?,
        isServerSync: Bool = true,
        logLabel: String
    ) async -> Bool where T.DomainModel: DomainSystemFields {
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
                    // Identical changeTags mean an identical server version; re-applying a stale snapshot can only regress
                    // newer merged fields.
                    if isServerSync,
                       let itemTag = item.changeTag, !itemTag.isEmpty, itemTag == target.changeTag
                    {
                        continue
                    }
                    target.update(from: item, isServerSync: isServerSync)
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
                    // Same guard as the scoped branch: only server-sourced passes may
                    // treat an identical changeTag as a no-op.
                    if isServerSync,
                       let itemTag = item.changeTag, !itemTag.isEmpty, itemTag == target.changeTag
                    {
                        continue
                    }
                    target.update(from: item, isServerSync: isServerSync)
                } else {
                    modelContext.insert(T(from: item))
                }
            }
            return true
        }
        let grouped = Dictionary(grouping: items) { T(from: $0).familyRecordName }
        var success = true
        for (family, group) in grouped {
            success = await performUpsert(T.self, group, familyRecordName: family.isEmpty ? nil : family, isServerSync: isServerSync, logLabel: logLabel) && success
        }
        return success
    }

    /// Deferred variant of batchUpsert that mutates the actor's ModelContext
    /// without saving, allowing the caller to coalesce multiple type batches
    /// into a single saveContext() at the transaction boundary.
    private func batchUpsertWithoutSave<T: CacheMergeable & CacheSystemFields>(
        _: T.Type,
        _ items: [T.DomainModel],
        familyRecordName: String?
    ) async -> Bool where T.DomainModel: DomainSystemFields {
        await performUpsert(T.self, items, familyRecordName: familyRecordName, logLabel: "batchUpsertWithoutSave")
    }

    private func batchUpsertWithoutSave<T: CacheMergeable & CacheSystemFields>(
        _: T.Type,
        _ items: [T.DomainModel],
        familyRecordName: String?,
        isServerSync: Bool
    ) async -> Bool where T.DomainModel: DomainSystemFields {
        await performUpsert(T.self, items, familyRecordName: familyRecordName, isServerSync: isServerSync, logLabel: "batchUpsertWithoutSave")
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

    // Purge and deletion helpers moved to BackgroundCacheActor+Maintenance.swift

    @discardableResult
    func saveContext() -> Bool {
        do {
            try modelContext.save()
            return true
        } catch {
            logger.error("Failed to save background context: \(error, privacy: .private)")
            return false
        }
    }
}

private extension Logger {
    func warning(_ message: String, family: String, zone: String) {
        log(level: .default, "\(message, privacy: .public) family=\(family, privacy: .private) zone=\(zone, privacy: .private)")
    }

    func info(_ message: String, family: String, zone: String) {
        log(level: .info, "\(message, privacy: .public) family=\(family, privacy: .private) zone=\(zone, privacy: .private)")
    }

    func error(_ message: String, family: String, zone: String) {
        log(level: .error, "\(message, privacy: .public) family=\(family, privacy: .private) zone=\(zone, privacy: .private)")
    }
}
