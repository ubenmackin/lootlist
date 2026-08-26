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

// swiftlint:disable type_body_length
@ModelActor
actor BackgroundCacheActor {
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "BackgroundCacheActor")

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

    private func purgeMissing<T: CacheMergeable>(
        _: T.Type,
        validRecordNames: Set<String>,
        familyRecordName: String?
    ) async {
        await purgeMissingWithoutSave(T.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
        saveContext()
    }

    /// Deferred variant of purgeMissing that deletes stale rows without
    /// saving, allowing multi-type reconciliations to coalesce the deletes
    /// into one saveContext() at the transaction boundary.
    private func purgeMissingWithoutSave<T: CacheMergeable>(
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

    // MARK: - Domain-model upserts

    /// Single-writer mirror of the main-actor upsert surface. Each family
    /// scope commits as its own unit — one merge pass followed by one save —
    /// so a failed save for one family never rolls into another family's
    /// already-committed rows.
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

    /// Delegates to shared helper so ledger/profile stay in one transaction
    /// and idempotency via deterministic ledger ID is enforced once. A partial
    /// prepare rolls back so an orphan credit row can never outlive its
    /// balance update under a later unrelated save.
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

    /// Debit mirror of the main-actor path: balance and ledger row mutate in
    /// one pass and commit together so a failed save can never split a
    /// debited profile from its ledger entry. A partial upsert rolls back
    /// instead of leaving one side dirty for a later unrelated save to flush
    /// alone; deterministic purchase IDs make the caller's retry a clean redo.
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

    /// Accounting for one reconciliation pass, letting callers observe parse
    /// and commit failures without this actor reaching into main-actor
    /// sync-pass state.
    struct ReconciliationOutcome: Sendable {
        var recordCount = 0
        var parseFailures = 0
        var commitSucceeded = false
    }

    /// Participant reconciliation: upserts a fetched shared-database snapshot
    /// and prunes rows the server no longer holds inside ONE queue-gated
    /// transaction ending in a single save, so @Query never observes a
    /// half-reconciled cache between the upsert and prune halves of the pass.
    ///
    /// - Parameters:
    ///   - validRecordNamesByType: server-authoritative record names per type;
    ///     cached rows absent from these sets are deleted after the upsert.
    ///   - databaseScope: must be `.shared`; owner-side flows ride the standard
    ///     ingestion path instead.
    /// - Returns: nil when the pass is skipped for a non-shared scope;
    ///   otherwise counts the caller surfaces in sync diagnostics.
    @discardableResult
    func reconcileParticipantSet(
        records: [CKRecord],
        validRecordNamesByType: [CachedRecordType: Set<String>],
        familyRecordName: String,
        databaseScope: CKDatabase.Scope,
        zoneID: CKRecordZone.ID
    ) async -> ReconciliationOutcome? {
        guard databaseScope == .shared else {
            logger.warning("Participant reconciliation skipped for non-shared scope")
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
            logger.warning("\(parseFailures) record(s) failed to parse during participant reconciliation")
        }
        let capturedBatch = batch
        let commitSucceeded = await SerialMutationQueue.shared.write {
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

    /// Single-transaction variant of the parsed-batch commit followed by a
    /// deferred purge per provided type. A failed commit leaves the context
    /// unsaved so nothing partial becomes visible; rows survive until the next
    /// reconciliation pass re-runs. The result feeds caller-side diagnostics
    /// only — commit semantics are unchanged.
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
            logger.error("Participant reconciliation upsert failed for zone \(zoneID.zoneName, privacy: .private)")
            return false
        }
        for (type, validRecordNames) in validRecordNamesByType {
            await purgeMissingOfType(type, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
        }
        guard saveContext() else {
            logger.error("Participant reconciliation save failed for zone \(zoneID.zoneName, privacy: .private)")
            return false
        }
        return true
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
        if !batch.goals.isEmpty {
            success = await batchUpsertWithoutSave(GoalCache.self, batch.goals, familyRecordName: nil) && success
        }
        return success
    }

    /// Shared upsert core: mutates the actor's ModelContext without saving so
    /// callers decide when to commit — single-type paths save immediately,
    /// while multi-type batches coalesce into one saveContext() at the
    /// transaction boundary. `logLabel` keeps log output identical to the
    /// original per-path messages.
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
                    // Identical changeTags mean an identical server version; re-applying a
                    // stale snapshot can only regress newer merged fields. Local optimistic
                    // writes keep their base tag while carrying real field deltas, so the
                    // guard must never swallow them.
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

    func purgeMissingFamilies(validRecordNames: Set<String>) async {
        await purgeMissing(FamilyCache.self, validRecordNames: validRecordNames, familyRecordName: nil)
    }

    /// Deferred purge dispatch for a runtime-resolved record type, letting
    /// callers keyed on `CachedRecordType` prune without per-type boilerplate.
    private func purgeMissingOfType(
        _ type: CachedRecordType,
        validRecordNames: Set<String>,
        familyRecordName: String?
    ) async {
        switch type {
        case .profile:
            await purgeMissingWithoutSave(ProfileCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
        case .family:
            await purgeMissingWithoutSave(FamilyCache.self, validRecordNames: validRecordNames, familyRecordName: nil)
        case .quest:
            await purgeMissingWithoutSave(QuestCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
        case .questTemplate:
            await purgeMissingWithoutSave(QuestTemplateCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
        case .questCompletion:
            await purgeMissingWithoutSave(QuestCompletionCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
        case .ledgerEntry:
            await purgeMissingWithoutSave(LedgerEntryCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
        case .allowancePeriod:
            await purgeMissingWithoutSave(AllowancePeriodCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
        case .achievement:
            await purgeMissingWithoutSave(AchievementCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
        case .profileAchievement:
            await purgeMissingWithoutSave(ProfileAchievementCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
        case .notificationPreference:
            await purgeMissingWithoutSave(NotificationPreferenceCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
        case .gemLedger:
            await purgeMissingWithoutSave(GemLedgerCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
        case .rewardEvent:
            await purgeMissingWithoutSave(RewardEventCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
        case .goal:
            await purgeMissingWithoutSave(GoalCache.self, validRecordNames: validRecordNames, familyRecordName: familyRecordName)
        }
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
        await purgeFamilyRows(GoalCache.self, familyRecordName: recordName)
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

    /// Typed deletion entry point. The caller supplies the active family
    /// zone so this actor never derives sync authority from
    /// device-local defaults itself.
    func deleteByIdentity(_ identity: ScopedRecordIdentity, type: CachedRecordType, expectedActiveZone: CKRecordZone.ID?) async {
        await performTypedDeletion(identity: identity, type: type, expectedActiveZone: expectedActiveZone)
        saveContext()
    }

    /// Shared fan-out so the ingestion path and the domain-write surface run
    /// identical typed deletions behind one save.
    private func performTypedDeletion(identity: ScopedRecordIdentity, type: CachedRecordType, expectedActiveZone: CKRecordZone.ID?) async {
        switch type {
        case .profile: await deleteRecordByIdentity(ProfileCache.self, identity: identity, expectedActiveZone: expectedActiveZone)
        case .family: await deleteRecordByIdentity(FamilyCache.self, identity: identity, expectedActiveZone: expectedActiveZone)
        case .quest: await deleteRecordByIdentity(QuestCache.self, identity: identity, expectedActiveZone: expectedActiveZone)
        case .questTemplate: await deleteRecordByIdentity(QuestTemplateCache.self, identity: identity, expectedActiveZone: expectedActiveZone)
        case .questCompletion: await deleteRecordByIdentity(QuestCompletionCache.self, identity: identity, expectedActiveZone: expectedActiveZone)
        case .ledgerEntry: await deleteRecordByIdentity(LedgerEntryCache.self, identity: identity, expectedActiveZone: expectedActiveZone)
        case .allowancePeriod: await deleteRecordByIdentity(AllowancePeriodCache.self, identity: identity, expectedActiveZone: expectedActiveZone)
        case .achievement: await deleteRecordByIdentity(AchievementCache.self, identity: identity, expectedActiveZone: expectedActiveZone)
        case .profileAchievement: await deleteRecordByIdentity(ProfileAchievementCache.self, identity: identity, expectedActiveZone: expectedActiveZone)
        case .notificationPreference: await deleteRecordByIdentity(NotificationPreferenceCache.self, identity: identity, expectedActiveZone: expectedActiveZone)
        case .gemLedger: await deleteRecordByIdentity(GemLedgerCache.self, identity: identity, expectedActiveZone: expectedActiveZone)
        case .rewardEvent: await deleteRecordByIdentity(RewardEventCache.self, identity: identity, expectedActiveZone: expectedActiveZone)
        case .goal: await deleteRecordByIdentity(GoalCache.self, identity: identity, expectedActiveZone: expectedActiveZone)
        }
    }

    func deleteByNameAndFamily<T: CacheMergeable & FamilyScopedCache>(
        type _: T.Type,
        recordName: String,
        familyRecordName: String
    ) async {
        let descriptor = FetchDescriptor<T>(predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == familyRecordName })
        do {
            let matches = try modelContext.fetch(descriptor)
            for match in matches {
                modelContext.delete(match)
            }
        } catch {
            logger.warning("Failed to fetch \(T.self, privacy: .public) for invalidation: \(error, privacy: .private)")
        }
        saveContext()
    }

    /// Typed fan-out mirroring performTypedDeletion for callers holding a
    /// runtime record type instead of a concrete cache class. Family rows are
    /// unscoped roots, so they cannot ride the family-scoped generic and are
    /// matched by record name alone.
    func deleteByNameAndFamily(
        _ type: CachedRecordType,
        recordName: String,
        familyRecordName: String
    ) async {
        switch type {
        case .profile:
            await deleteByNameAndFamily(type: ProfileCache.self, recordName: recordName, familyRecordName: familyRecordName)
        case .family:
            do {
                if let match = try modelContext.fetch(FetchDescriptor<FamilyCache>(predicate: #Predicate { $0.recordName == recordName })).first {
                    modelContext.delete(match)
                }
            } catch {
                logger.warning("Failed to fetch FamilyCache for invalidation: \(error, privacy: .private)")
            }
        case .quest:
            await deleteByNameAndFamily(type: QuestCache.self, recordName: recordName, familyRecordName: familyRecordName)
        case .questTemplate:
            await deleteByNameAndFamily(type: QuestTemplateCache.self, recordName: recordName, familyRecordName: familyRecordName)
        case .questCompletion:
            await deleteByNameAndFamily(type: QuestCompletionCache.self, recordName: recordName, familyRecordName: familyRecordName)
        case .ledgerEntry:
            await deleteByNameAndFamily(type: LedgerEntryCache.self, recordName: recordName, familyRecordName: familyRecordName)
        case .allowancePeriod:
            await deleteByNameAndFamily(type: AllowancePeriodCache.self, recordName: recordName, familyRecordName: familyRecordName)
        case .achievement:
            await deleteByNameAndFamily(type: AchievementCache.self, recordName: recordName, familyRecordName: familyRecordName)
        case .profileAchievement:
            await deleteByNameAndFamily(type: ProfileAchievementCache.self, recordName: recordName, familyRecordName: familyRecordName)
        case .notificationPreference:
            await deleteByNameAndFamily(type: NotificationPreferenceCache.self, recordName: recordName, familyRecordName: familyRecordName)
        case .gemLedger:
            await deleteByNameAndFamily(type: GemLedgerCache.self, recordName: recordName, familyRecordName: familyRecordName)
        case .rewardEvent:
            await deleteByNameAndFamily(type: RewardEventCache.self, recordName: recordName, familyRecordName: familyRecordName)
        case .goal:
            await deleteByNameAndFamily(type: GoalCache.self, recordName: recordName, familyRecordName: familyRecordName)
        }
        saveContext()
    }

    /// Sign-out-scale wipe of every cached row. Runs inside the mutation
    /// queue so an in-flight ingestion batch cannot repopulate rows between
    /// the deletes and the save; freshness watermarks are device-local
    /// UserDefaults state and stay with CacheService.
    func clearAllCachedRows() async {
        await SerialMutationQueue.shared.write {
            await self.clearAllCachedRowsInTransaction()
        }
    }

    private func clearAllCachedRowsInTransaction() async {
        do {
            try modelContext.delete(model: QuestCache.self)
            try modelContext.delete(model: QuestTemplateCache.self)
            try modelContext.delete(model: ProfileCache.self)
            try modelContext.delete(model: QuestCompletionCache.self)
            try modelContext.delete(model: FamilyCache.self)
            try modelContext.delete(model: LedgerEntryCache.self)
            try modelContext.delete(model: AllowancePeriodCache.self)
            try modelContext.delete(model: AchievementCache.self)
            try modelContext.delete(model: ProfileAchievementCache.self)
            try modelContext.delete(model: NotificationPreferenceCache.self)
            try modelContext.delete(model: GemLedgerCache.self)
            try modelContext.delete(model: RewardEventCache.self)
            try modelContext.delete(model: GoalCache.self)
        } catch {
            logger.error("Failed to delete cached rows: \(error, privacy: .private)")
        }
        guard saveContext() else {
            logger.error("Failed to save after clearing cache")
            return
        }
    }

    private func deleteRecordByIdentity<T: CacheMergeable>(
        _: T.Type,
        identity: ScopedRecordIdentity,
        expectedActiveZone: CKRecordZone.ID?
    ) async {
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
                let isActiveZone = expectedActiveZone.map { $0 == identity.zoneID } ?? false
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

// swiftlint:enable type_body_length
