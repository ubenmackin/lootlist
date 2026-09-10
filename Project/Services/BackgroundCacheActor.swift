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

/// Background cache writer managing off-main SwiftData writes.
@ModelActor
actor BackgroundCacheActor {
    let logger = Logger(category: "BackgroundCacheActor")
    let mutationQueue = SerialMutationQueue.shared

    /// Creates the background cache actor off-main to avoid main-thread affinity.
    static func makeBackgroundWriter(for container: ModelContainer) async -> BackgroundCacheActor {
        await Task.detached(priority: .userInitiated) {
            BackgroundCacheActor(container: container)
        }.value
    }

    init(container: ModelContainer) {
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
        let needed = Set(nameless.map(\.template.recordID.recordName))
        var zoneByName: [String: CKRecordZone.ID] = [:]
        zoneByName.reserveCapacity(needed.count)
        var familyByName: [String: String] = [:]
        familyByName.reserveCapacity(needed.count)
        for quest in nameless {
            let key = quest.template.recordID.recordName
            zoneByName[key] = quest.template.recordID.zoneID
            familyByName[key] = quest.family.recordID.recordName
        }
        // WHY cache-first: template rows already synced render instantly; CloudKit covers gaps only.
        // WHY indexed probes: per-ID family+recordName rides the composite index, never scans the family table.
        var cachedByName: [String: QuestTemplate] = [:]
        for name in needed {
            guard let familyName = familyByName[name], !familyName.isEmpty, let zone = zoneByName[name] else { continue }
            do {
                var descriptor = QuestTemplateCache.fetchDescriptor(recordName: name, familyRecordName: familyName)
                descriptor.fetchLimit = 1
                if let row = try modelContext.fetch(descriptor).first {
                    cachedByName[name] = row.toQuestTemplate(zoneID: zone)
                }
            } catch {
                logger.error("Failed to fetch QuestTemplateCache for quest-name backfill: \(error, privacy: .private)")
            }
        }
        let cached = Array(cachedByName.values)
        let log = logger
        // WHY batched stitch: one concurrent missing-ID pass replaces the per-row CloudKit N+1.
        // WHY transient: backfill patches names in-memory for display; snapshot reconciliation persists templates via ingest.
        let stitched: [QuestTemplate]
        do {
            stitched = try await CacheFirst.stitch(needed: needed, cached: cached) { missing in
                var fetched: [QuestTemplate] = []
                let grouped = Dictionary(grouping: missing) { familyByName[$0] ?? "" }
                for (familyName, names) in grouped {
                    guard !familyName.isEmpty, let zone = names.compactMap({ zoneByName[$0] }).first else { continue }
                    let family = Family(name: "", creatorUserRecordName: nil, id: CKRecord.ID(recordName: familyName, zoneID: zone))
                    do {
                        let batch: [QuestTemplate] = try await BatchQuestFetcher.fetchMissingQuests(names: names, family: family, cloudKit: cloudKit)
                        fetched.append(contentsOf: batch)
                    } catch {
                        log.debug("Failed to batch-fetch templates for backfill \(familyName, privacy: .private): \(error, privacy: .private)")
                    }
                }
                return fetched
            }
        } catch {
            logger.debug("Failed to stitch templates for quest-name backfill: \(error, privacy: .private)")
            let cachedByID = Dictionary(uniqueKeysWithValues: cached.map { ($0.id.recordName, $0) })
            return quests.map { quest in
                guard quest.name == nil, let template = cachedByID[quest.template.recordID.recordName] else { return quest }
                var updated = quest
                updated.name = template.name
                return updated
            }
        }
        let templatesByID = Dictionary(uniqueKeysWithValues: stitched.map { ($0.id.recordName, $0) })
        return quests.map { quest in
            guard quest.name == nil, let template = templatesByID[quest.template.recordID.recordName] else { return quest }
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
        isServerSync: Bool,
        explicitScope: CKDatabase.Scope? = nil
    ) async where M.DomainModel: DomainSystemFields {
        guard !items.isEmpty else { return }
        if let familyRecordName {
            _ = await performUpsert(M.self, items, familyRecordName: familyRecordName, isServerSync: isServerSync, explicitScope: explicitScope, logLabel: "upsertDomainModels")
            saveContext()
            return
        }
        // Families are unscoped roots; every other type splits by its own
        // family scope so each group commits independently.
        if M.self == FamilyCache.self {
            _ = await performUpsert(M.self, items, familyRecordName: nil, isServerSync: isServerSync, explicitScope: explicitScope, logLabel: "upsertDomainModels")
            saveContext()
            return
        }
        let grouped = groupedByFamily(M.self, items: items)
        for (family, group) in grouped {
            _ = await performUpsert(
                M.self,
                group,
                familyRecordName: family.isEmpty ? nil : family,
                isServerSync: isServerSync,
                explicitScope: explicitScope,
                logLabel: "upsertDomainModels"
            )
            saveContext()
        }
    }

    func upsertDomainModel<M: CacheMergeable & CacheSystemFields>(
        _ item: M.DomainModel,
        type: M.Type,
        familyRecordName: String?,
        isServerSync: Bool,
        explicitScope: CKDatabase.Scope? = nil
    ) async where M.DomainModel: DomainSystemFields {
        await upsertDomainModels([item], type: type, familyRecordName: familyRecordName, isServerSync: isServerSync, explicitScope: explicitScope)
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
        let isServerSync = false
        var success = true
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

    private func upsertGroupedWithoutSave<T: CacheMergeable & CacheSystemFields>(
        _: T.Type,
        _ items: [T.DomainModel],
        familyRecordName: String?,
        isServerSync: Bool,
        familyKey: (T.DomainModel) -> String
    ) async -> Bool where T.DomainModel: DomainSystemFields {
        let grouped = Dictionary(grouping: items, by: familyKey)
        var ok = true
        for (fam, group) in grouped {
            let targetFamily = familyRecordName ?? fam
            ok = await performUpsert(
                T.self,
                group,
                familyRecordName: targetFamily,
                isServerSync: isServerSync,
                logLabel: "batchUpsertLedgerAndGoalEntitiesGrouped"
            ) && ok
        }
        return ok
    }

    // Pending re-enqueue scan helpers live in BackgroundCacheActor+Unsynced.swift

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

        /// WHY committed set gates stamping: only types with rows written may stamp fresh.
        var committedTypes: Set<CachedRecordType> {
            var types: Set<CachedRecordType> = []
            if !families.isEmpty {
                types.insert(.family)
            }
            if !profiles.isEmpty {
                types.insert(.profile)
            }
            if !quests.isEmpty {
                types.insert(.quest)
            }
            if !templates.isEmpty {
                types.insert(.questTemplate)
            }
            if !completions.isEmpty {
                types.insert(.questCompletion)
            }
            if !ledgerEntries.isEmpty {
                types.insert(.ledgerEntry)
            }
            if !periods.isEmpty {
                types.insert(.allowancePeriod)
            }
            if !achievements.isEmpty {
                types.insert(.achievement)
            }
            if !profileAchievements.isEmpty {
                types.insert(.profileAchievement)
            }
            if !notificationPrefs.isEmpty {
                types.insert(.notificationPreference)
            }
            if !rewardEvents.isEmpty {
                types.insert(.rewardEvent)
            }
            if !gemLedgers.isEmpty {
                types.insert(.gemLedger)
            }
            if !goals.isEmpty {
                types.insert(.goal)
            }
            return types
        }
    }

    @discardableResult
    func batchUpsertParsedRecords(_ records: [ParsedRecord], databaseScope: CKDatabase.Scope? = nil) async -> Bool {
        var batch = ParsedBatch()
        for record in records {
            batch.append(record)
        }
        let capturedBatch = batch
        return await mutationQueue.write {
            await self.commitParsedBatch(capturedBatch, databaseScope: databaseScope)
        }
    }

    struct ReconciliationOutcome: Sendable {
        var recordCount = 0
        var parseFailures = 0
        var commitSucceeded = false
        var failedTypes: Set<CachedRecordType> = []
        var committedTypes: Set<CachedRecordType> = []
    }

    /// Participant reconciliation — single commit with atomic saveContext.
    @discardableResult
    func reconcileParticipantSet(
        records: [CKRecord],
        validRecordNamesByType: [CachedRecordType: Set<String>],
        familyRecordName: String,
        databaseScope: CKDatabase.Scope,
        zoneID: CKRecordZone.ID
    ) async -> ReconciliationOutcome? {
        guard databaseScope == .shared else {
            logger.warning("Participant reconciliation skipped for non-shared scope", family: familyRecordName, zone: zoneID.zoneName)
            return nil
        }
        let parsedRecords = await MainActor.run {
            records.map { ParsedRecord.parse(record: $0) }
        }
        var parseFailures = 0
        var failedTypes: Set<CachedRecordType> = []
        var batch = ParsedBatch()
        for parsed in parsedRecords {
            if case let .parseFailure(recordType, _) = parsed {
                parseFailures += 1
                // WHY: unknown record types carry no freshness watermark, so only known types gate per-type stamping.
                if let failedType = CachedRecordType.recordType(for: recordType) {
                    failedTypes.insert(failedType)
                }
            }
            batch.append(parsed)
        }
        if parseFailures > 0 {
            logger.warning("\(parseFailures) record(s) failed to parse during participant reconciliation", family: familyRecordName, zone: zoneID.zoneName)
        }
        let capturedBatch = batch
        let committedTypes = capturedBatch.committedTypes
        let commitSucceeded = await mutationQueue.write {
            await self.commitParticipantReconciliation(
                capturedBatch,
                validRecordNamesByType: validRecordNamesByType,
                familyRecordName: familyRecordName,
                databaseScope: databaseScope,
                zoneID: zoneID
            )
        }
        return ReconciliationOutcome(
            recordCount: records.count,
            parseFailures: parseFailures,
            commitSucceeded: commitSucceeded,
            failedTypes: failedTypes,
            committedTypes: committedTypes
        )
    }

    private func commitParticipantReconciliation(
        _ batch: ParsedBatch,
        validRecordNamesByType: [CachedRecordType: Set<String>],
        familyRecordName: String,
        databaseScope: CKDatabase.Scope,
        zoneID: CKRecordZone.ID
    ) async -> Bool {
        var success = true
        success = await commitCoreEntitiesDeferred(batch, databaseScope: databaseScope) && success
        success = await commitSecondaryEntitiesDeferred(batch, databaseScope: databaseScope) && success
        guard success else {
            // WHY fail-closed: partial reconciliation must not commit or @Query observes half-ingested state.
            modelContext.rollback()
            logger.error("Participant reconciliation upsert failed", family: familyRecordName, zone: zoneID.zoneName)
            return false
        }
        // WHY: Unacked rows are missing server-side until re-enqueue uploads them; purging would drop them first.
        let pending = collectPendingNames(familyRecordName: familyRecordName)
        for (type, validRecordNames) in validRecordNamesByType {
            // WHY root exception: family is the partition so reconciliation never purges other families' roots.
            guard type != .family else { continue }
            await purgeMissingOfType(type, validRecordNames: validRecordNames, familyRecordName: familyRecordName, preservedRecordNames: pending[type] ?? [])
        }
        guard saveContext() else {
            // WHY fail-closed: save failure must discard dirty rows so next pass never observes half-reconciled state.
            modelContext.rollback()
            logger.error("Participant reconciliation save failed", family: familyRecordName, zone: zoneID.zoneName)
            return false
        }
        return true
    }

    /// Accumulates all inserts/updates and saves the ModelContext exactly once — the single
    /// saveContext() that triggers SwiftData change notifications for @Query views.
    private func commitParsedBatch(_ batch: ParsedBatch, databaseScope: CKDatabase.Scope?) async -> Bool {
        var success = true
        success = await commitCoreEntitiesDeferred(batch, databaseScope: databaseScope) && success
        success = await commitSecondaryEntitiesDeferred(batch, databaseScope: databaseScope) && success
        guard success else {
            // WHY fail-closed: partial batch must not commit or @Query observes half-ingested state.
            modelContext.rollback()
            return false
        }
        guard saveContext() else {
            // WHY fail-closed: save failure must discard dirty rows so next pass never observes half-ingested state.
            modelContext.rollback()
            logger.error("Parsed batch save failed")
            return false
        }
        return true
    }

    private func commitCoreEntitiesDeferred(_ batch: ParsedBatch, databaseScope: CKDatabase.Scope?) async -> Bool {
        var success = true
        if !batch.families.isEmpty {
            success = await batchUpsertWithoutSave(FamilyCache.self, batch.families, familyRecordName: nil, explicitScope: databaseScope) && success
        }
        if !batch.profiles.isEmpty {
            success = await batchUpsertWithoutSave(ProfileCache.self, batch.profiles, familyRecordName: nil, explicitScope: databaseScope) && success
        }
        if !batch.quests.isEmpty {
            success = await batchUpsertWithoutSave(QuestCache.self, batch.quests, familyRecordName: nil, explicitScope: databaseScope) && success
        }
        if !batch.templates.isEmpty {
            success = await batchUpsertWithoutSave(QuestTemplateCache.self, batch.templates, familyRecordName: nil, explicitScope: databaseScope) && success
        }
        if !batch.completions.isEmpty {
            success = await batchUpsertWithoutSave(QuestCompletionCache.self, batch.completions, familyRecordName: nil, explicitScope: databaseScope) && success
            success = await reconcileStoredRewardEventsWithoutSave(for: batch.completions) && success
        }
        return success
    }

    private func commitSecondaryEntitiesDeferred(_ batch: ParsedBatch, databaseScope: CKDatabase.Scope?) async -> Bool {
        var success = true
        if !batch.ledgerEntries.isEmpty {
            success = await batchUpsertWithoutSave(LedgerEntryCache.self, batch.ledgerEntries, familyRecordName: nil, explicitScope: databaseScope) && success
        }
        if !batch.periods.isEmpty {
            success = await batchUpsertWithoutSave(AllowancePeriodCache.self, batch.periods, familyRecordName: nil, explicitScope: databaseScope) && success
        }
        if !batch.achievements.isEmpty {
            success = await batchUpsertWithoutSave(AchievementCache.self, batch.achievements, familyRecordName: nil, explicitScope: databaseScope) && success
        }
        if !batch.profileAchievements.isEmpty {
            success = await batchUpsertWithoutSave(ProfileAchievementCache.self, batch.profileAchievements, familyRecordName: nil, explicitScope: databaseScope) && success
        }
        if !batch.notificationPrefs.isEmpty {
            success = await batchUpsertWithoutSave(NotificationPreferenceCache.self, batch.notificationPrefs, familyRecordName: nil, explicitScope: databaseScope) && success
        }
        if !batch.gemLedgers.isEmpty {
            success = await batchUpsertWithoutSave(GemLedgerCache.self, batch.gemLedgers, familyRecordName: nil, explicitScope: databaseScope) && success
        }
        if !batch.rewardEvents.isEmpty {
            success = await batchUpsertWithoutSave(RewardEventCache.self, batch.rewardEvents, familyRecordName: nil, explicitScope: databaseScope) && success
            success = await reconcileRewardEventsWithoutSave(batch.rewardEvents) && success
        }
        if !batch.goals.isEmpty {
            success = await batchUpsertWithoutSave(GoalCache.self, batch.goals, familyRecordName: nil, explicitScope: databaseScope) && success
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
        explicitScope: CKDatabase.Scope? = nil,
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
                    // Stale server snapshot guard: skip if identical server changeTag, but always apply local writes.
                    if isServerSync,
                       let itemTag = item.changeTag, !itemTag.isEmpty, itemTag == target.changeTag
                    {
                        continue
                    }
                    target.update(from: item, isServerSync: isServerSync)
                    target.applyExplicitDatabaseScope(explicitScope, from: item)
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
                    newRow.applyExplicitDatabaseScope(explicitScope, from: item)
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
                    // Stale server snapshot guard: skip if identical server changeTag, but always apply local writes.
                    if isServerSync,
                       let itemTag = item.changeTag, !itemTag.isEmpty, itemTag == target.changeTag
                    {
                        continue
                    }
                    target.update(from: item, isServerSync: isServerSync)
                    target.applyExplicitDatabaseScope(explicitScope, from: item)
                } else {
                    let newRow = T(from: item)
                    newRow.applyExplicitDatabaseScope(explicitScope, from: item)
                    modelContext.insert(newRow)
                }
            }
            return true
        }
        let grouped = groupedByFamily(T.self, items: items)
        var success = true
        for (family, group) in grouped {
            success = await performUpsert(
                T.self,
                group,
                familyRecordName: family.isEmpty ? nil : family,
                isServerSync: isServerSync,
                explicitScope: explicitScope,
                logLabel: logLabel
            ) && success
        }
        return success
    }

    /// Deferred variant of batchUpsert that mutates the actor's ModelContext
    /// without saving, allowing the caller to coalesce multiple type batches
    /// into a single saveContext() at the transaction boundary.
    private func batchUpsertWithoutSave<T: CacheMergeable & CacheSystemFields>(
        _: T.Type,
        _ items: [T.DomainModel],
        familyRecordName: String?,
        isServerSync: Bool = true,
        explicitScope: CKDatabase.Scope? = nil
    ) async -> Bool where T.DomainModel: DomainSystemFields {
        await performUpsert(T.self, items, familyRecordName: familyRecordName, isServerSync: isServerSync, explicitScope: explicitScope, logLabel: "batchUpsertWithoutSave")
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

    // MARK: - Conflict baseline reads

    func lastSyncedXP(recordName: String, familyRecordName: String) async -> Int? {
        // WHY fail-closed: empty scope must never match a baseline row.
        guard !recordName.isEmpty, !familyRecordName.isEmpty else { return nil }
        return await mutationQueue.write {
            await self.fetchLastSyncedXP(recordName: recordName, familyRecordName: familyRecordName)
        }
    }

    private func fetchLastSyncedXP(recordName: String, familyRecordName: String) async -> Int? {
        // WHY indexed probe: baseline read rides the composite index so the conflict path never scans.
        var descriptor = ProfileCache.fetchDescriptor(recordName: recordName, familyRecordName: familyRecordName)
        descriptor.fetchLimit = 1
        do {
            return try modelContext.fetch(descriptor).first?.lastSyncedXP
        } catch {
            logger.error("Failed to fetch ProfileCache baseline: \(error, privacy: .private)")
            return nil
        }
    }

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
