//
//  SyncEngine.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import Observation
import os
import Synchronization

@MainActor
@Observable
final class SyncEngine {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "LootList",
        category: "SyncEngine"
    )

    private let cloudKit: CloudKitService
    private let cacheService: CacheService
    private let backgroundCache: BackgroundCacheActor
    private let syncCoordinator: AppSyncCoordinator

    private(set) var isSyncing: Bool = false
    private enum PendingSync: Comparable { case none, incremental, full }
    private var pendingSync: PendingSync = .none
    private(set) var lastSyncedAt: Date?
    var syncError: String?

    /// Zone names (== family record names, TASK-001) flagged for a full re-sync
    /// because a prior incremental pass hit records it could not parse (S3).
    /// Consumed by the next `syncAll`/`incrementalSync`; never persisted across
    /// launches — the deliberately un-advanced change token already forces the
    /// full-sync fallback there.
    private(set) var needsFullResyncZoneNames: Set<String> = []

    /// Record names that failed to parse during the current incremental sync
    /// pass (S3). The set is count-limited so a pathological zone cannot grow
    /// memory without bound; `failedRecordCount` stays exact and non-zero is
    /// the signal that the zone change token must not advance.
    private static let maxTrackedFailedRecords = 100
    private var failedRecordNames: Set<String> = []
    private var failedRecordCount = 0

    private let syncTaskMutex = Mutex<Task<Void, Never>?>(nil)

    init(cloudKit: CloudKitService,
         cacheService: CacheService,
         backgroundCache: BackgroundCacheActor,
         syncCoordinator: AppSyncCoordinator)
    {
        self.cloudKit = cloudKit
        self.cacheService = cacheService
        self.backgroundCache = backgroundCache
        self.syncCoordinator = syncCoordinator

        listenToPushNotifications()
    }

    nonisolated deinit {
        syncTaskMutex.withLock { $0?.cancel() }
    }

    /// Full sync scoped to a single family zone.
    func syncAll(familyRecordName: String) async {
        await _syncAll(familyRecordName: familyRecordName)
    }

    /// Full sync for the currently resolved family zone.
    ///
    /// The CloudKit zone is named after the Family record, so the resolved
    /// zone's name IS the concrete `familyRecordName` this sync is scoped to.
    /// This method hydrates ONLY the currently resolved family zone — there is
    /// no "all families" bootstrap, because the active zone is the single
    /// source of family data this device serves at any one time. The purge
    /// paths are scoped to that family so other families' cached rows are never
    /// deleted (D1).
    func syncAllForActiveZone() async {
        await _syncAll(familyRecordName: cloudKit.resolvedZoneID.zoneName)
    }

    /// Shared implementation for scoped full syncs.
    ///
    /// D1 guard: the purge path MUST always be scoped to a concrete
    /// `familyRecordName`. When the caller supplies nil (or an empty scope),
    /// derive the effective scope from `cloudKit.resolvedZoneID.zoneName`
    /// (the zone is named after the Family record) BEFORE any fetch, so a
    /// nil family scope can never reach a `purgeMissing*` call — a
    /// cross-family data-loss hazard in multi-family scenarios.
    private func _syncAll(familyRecordName: String?) async {
        if isSyncing {
            logger.info("Sync already in progress, skipping full sync (queued as pending)")
            pendingSync = .full
            return
        }

        // Derive the concrete family scope BEFORE fetching. The zone is named
        // after the Family record, so the resolved zone's name is the family
        // record name. A nil/empty caller scope falls back to this value so
        // every `batchUpsert*` and `purgeMissing*` call below receives a
        // concrete scope — never a nil that could purge another family's rows.
        let resolvedFamilyRecordName = resolveFamilyRecordName(familyRecordName)

        // S3: a prior incremental pass could not parse a record in this zone and
        // deliberately did not advance the change token. This full re-sync
        // re-reads every record, so consuming the flag here satisfies the
        // "full re-sync on the next opportunity" contract.
        needsFullResyncZoneNames.remove(resolvedFamilyRecordName)

        isSyncing = true
        pendingSync = .none
        syncError = nil
        var syncErrors: [String] = []
        var recordsChanged = false

        defer {
            isSyncing = false
            lastSyncedAt = Date()
            let outcome: SyncOutcome = syncErrors.isEmpty ? (recordsChanged ? .changed : .noChange) : .failed
            var userInfo: [String: Any] = [SyncOutcome.userInfoKey: outcome]
            if !syncErrors.isEmpty {
                userInfo["errors"] = syncErrors
            }
            NotificationCenter.default.post(name: .syncDidComplete, object: self, userInfo: userInfo)
            dispatchPendingSync(familyRecordName: resolvedFamilyRecordName)
        }

        logger.info("Starting syncAll for familyRecordName=\(resolvedFamilyRecordName, privacy: .private)")
        await fetchAndCacheAllEntities(familyRecordName: resolvedFamilyRecordName, syncErrors: &syncErrors, recordsChanged: &recordsChanged)
        logger.info("syncAll completed successfully.")
    }

    private func fetchAndCacheAllEntities(familyRecordName: String, syncErrors: inout [String], recordsChanged: inout Bool) async {
        await fetchAndCachePrimaryEntities(familyRecordName: familyRecordName, syncErrors: &syncErrors, recordsChanged: &recordsChanged)
        await fetchAndCacheSecondaryEntities(familyRecordName: familyRecordName, syncErrors: &syncErrors, recordsChanged: &recordsChanged)
    }

    private func fetchAndCachePrimaryEntities(familyRecordName: String, syncErrors: inout [String], recordsChanged: inout Bool) async {
        await syncEntityGroup(
            Family.self,
            name: "family",
            errorTag: "Family",
            cachedType: .family,
            familyRecordName: familyRecordName,
            syncErrors: &syncErrors,
            recordsChanged: &recordsChanged
        ) { families in
            await backgroundCache.batchUpsertFamilies(families)
            await backgroundCache.purgeMissingFamilies(validRecordNames: Set(families.map(\.id.recordName)))
        }

        await syncEntityGroup(
            NotificationPreference.self,
            name: "notification preferences",
            errorTag: "NotificationPreferences",
            cachedType: .notificationPreference,
            familyRecordName: familyRecordName,
            syncErrors: &syncErrors,
            recordsChanged: &recordsChanged
        ) { notifPrefs in
            await backgroundCache.batchUpsertNotificationPreferences(notifPrefs, familyRecordName: familyRecordName)
            await backgroundCache.purgeMissingNotificationPreferences(validRecordNames: Set(notifPrefs.map(\.id.recordName)), familyRecordName: familyRecordName)
        }

        await syncEntityGroup(
            Profile.self,
            name: "profiles",
            errorTag: "Profiles",
            cachedType: .profile,
            familyRecordName: familyRecordName,
            syncErrors: &syncErrors,
            recordsChanged: &recordsChanged
        ) { profiles in
            await backgroundCache.batchUpsertProfiles(profiles, familyRecordName: familyRecordName)
            await backgroundCache.purgeMissingProfiles(validRecordNames: Set(profiles.map(\.id.recordName)), familyRecordName: familyRecordName)
        }

        await syncEntityGroup(
            Quest.self,
            name: "quests",
            errorTag: "Quests",
            cachedType: .quest,
            familyRecordName: familyRecordName,
            syncErrors: &syncErrors,
            recordsChanged: &recordsChanged
        ) { quests in
            let stamped = await backgroundCache.backfillQuestNames(quests, cloudKit: cloudKit)
            await backgroundCache.batchUpsertQuests(stamped, familyRecordName: familyRecordName)
            await backgroundCache.purgeMissingQuests(validRecordNames: Set(quests.map(\.id.recordName)), familyRecordName: familyRecordName)
        }

        await syncEntityGroup(
            QuestTemplate.self,
            name: "quest templates",
            errorTag: "QuestTemplates",
            cachedType: .questTemplate,
            familyRecordName: familyRecordName,
            syncErrors: &syncErrors,
            recordsChanged: &recordsChanged
        ) { templates in
            await backgroundCache.batchUpsertQuestTemplates(templates, familyRecordName: familyRecordName)
            await backgroundCache.purgeMissingQuestTemplates(validRecordNames: Set(templates.map(\.id.recordName)), familyRecordName: familyRecordName)
        }
    }

    private func fetchAndCacheSecondaryEntities(familyRecordName: String, syncErrors: inout [String], recordsChanged: inout Bool) async {
        await syncEntityGroup(
            QuestCompletion.self,
            name: "quest completions",
            errorTag: "QuestCompletions",
            cachedType: .questCompletion,
            familyRecordName: familyRecordName,
            syncErrors: &syncErrors,
            recordsChanged: &recordsChanged
        ) { completions in
            await backgroundCache.batchUpsertQuestCompletions(completions, familyRecordName: familyRecordName)
            await backgroundCache.purgeMissingQuestCompletions(validRecordNames: Set(completions.map(\.id.recordName)), familyRecordName: familyRecordName)
        }

        await syncEntityGroup(
            LedgerEntry.self,
            name: "ledger entries",
            errorTag: "LedgerEntries",
            cachedType: .ledgerEntry,
            familyRecordName: familyRecordName,
            syncErrors: &syncErrors,
            recordsChanged: &recordsChanged
        ) { ledgerEntries in
            await backgroundCache.batchUpsertLedgerEntries(ledgerEntries, familyRecordName: familyRecordName)
            await backgroundCache.purgeMissingLedgerEntries(validRecordNames: Set(ledgerEntries.map(\.id.recordName)), familyRecordName: familyRecordName)
        }

        await syncEntityGroup(
            AllowancePeriod.self,
            name: "allowance periods",
            errorTag: "AllowancePeriods",
            cachedType: .allowancePeriod,
            familyRecordName: familyRecordName,
            syncErrors: &syncErrors,
            recordsChanged: &recordsChanged
        ) { allowancePeriods in
            await backgroundCache.batchUpsertAllowancePeriods(allowancePeriods, familyRecordName: familyRecordName)
            await backgroundCache.purgeMissingAllowancePeriods(validRecordNames: Set(allowancePeriods.map(\.id.recordName)), familyRecordName: familyRecordName)
        }

        await syncEntityGroup(
            Achievement.self,
            name: "achievements",
            errorTag: "Achievements",
            cachedType: .achievement,
            familyRecordName: familyRecordName,
            syncErrors: &syncErrors,
            recordsChanged: &recordsChanged
        ) { achievements in
            await backgroundCache.batchUpsertAchievements(achievements, familyRecordName: familyRecordName)
            await backgroundCache.purgeMissingAchievements(validRecordNames: Set(achievements.map(\.id.recordName)), familyRecordName: familyRecordName)
        }

        await syncEntityGroup(
            ProfileAchievement.self,
            name: "profile achievements",
            errorTag: "ProfileAchievements",
            cachedType: .profileAchievement,
            familyRecordName: familyRecordName,
            syncErrors: &syncErrors,
            recordsChanged: &recordsChanged
        ) { profileAchievements in
            await backgroundCache.batchUpsertProfileAchievements(profileAchievements, familyRecordName: familyRecordName)
            await backgroundCache.purgeMissingProfileAchievements(validRecordNames: Set(profileAchievements.map(\.id.recordName)), familyRecordName: familyRecordName)
        }
    }

    private func syncEntityGroup<T: CloudKitRecord>(
        _: T.Type,
        name: String,
        errorTag: String,
        cachedType: CachedRecordType,
        familyRecordName: String,
        syncErrors: inout [String],
        recordsChanged: inout Bool,
        process: @MainActor ([T]) async -> Void
    ) async {
        do {
            let entities = try await cloudKit.query(T.self, predicate: NSPredicate(value: true), in: cloudKit.resolvedZoneID)
            if !entities.isEmpty {
                recordsChanged = true
            }
            await process(entities)
            // Stamp freshness AFTER the batch upsert + purgeMissing pass
            // completes without throwing. A stamp means "this family + type is
            // fully synced" — the read-first gates serve partial caches only
            // when the stamp exists. An empty result set still stamps:
            // an empty zone IS a complete sync of that type.
            cacheService.markCacheFresh(familyRecordName: familyRecordName, type: cachedType)
        } catch {
            logger.error("Failed to sync \(name): \(error)")
            syncErrors.append("\(errorTag): \(error.localizedDescription)")
        }
    }

    /// Incremental delta sync using CKServerChangeToken for a specific family.
    func incrementalSync(familyRecordName: String? = nil) async {
        if isSyncing {
            logger.info("Sync already in progress, skipping incremental sync (queued as pending)")
            if pendingSync < .full {
                pendingSync = .incremental
            }
            return
        }

        isSyncing = true
        pendingSync = .none
        syncError = nil
        failedRecordNames.removeAll()
        failedRecordCount = 0
        var recordsChanged = false
        var didDelegateToFullSync = false

        defer {
            if !didDelegateToFullSync {
                isSyncing = false
                lastSyncedAt = Date()
                let outcome: SyncOutcome = syncError == nil ? (recordsChanged ? .changed : .noChange) : .failed
                NotificationCenter.default.post(name: .syncDidComplete, object: self, userInfo: [SyncOutcome.userInfoKey: outcome])
                // After saving the change token marking byte progress, set pendingSync = incremental if moreComing.
                // The next call will resume from the checkpoint token.
                dispatchPendingSync(familyRecordName: familyRecordName)
            }
        }

        let zoneID = cloudKit.resolvedZoneID
        let tokenKey = tokenKey(for: zoneID, isShared: !cloudKit.activeIsOwner)

        // A previous incremental pass hit unparseable records in this zone,
        // so the change token was deliberately not advanced — replaying it
        // would just re-hit the same malformed records. Escalate to a full
        // re-sync, which re-reads every record and keeps them retryable.
        if needsFullResyncZoneNames.remove(zoneID.zoneName) != nil {
            logger.warning("Zone \(zoneID.zoneName, privacy: .private) flagged for full re-sync after unparseable records; running syncAll")
            isSyncing = false
            didDelegateToFullSync = true
            await dispatchFullSync(familyRecordName: familyRecordName)
            return
        }

        guard let token = loadChangeToken(key: tokenKey) else {
            logger.info("No server change token found, executing syncAll(familyRecordName: \(familyRecordName ?? "all", privacy: .private))")
            isSyncing = false
            didDelegateToFullSync = true
            await dispatchFullSync(familyRecordName: familyRecordName)
            return
        }

        logger.info("Starting incrementalSync with change token")
        do {
            let result = try await cloudKit.fetchZoneChanges(since: token)
            recordsChanged = !result.changedRecords.isEmpty || !result.deletedRecordIDs.isEmpty
            let touchedTypes = await processIncrementalChanges(result)

            if self.failedRecordCount > 0 {
                // Skip advancing token if parsing failed and schedule full re-sync.
                logger.warning(
                    "\(self.failedRecordCount) record(s) failed to parse in zone \(zoneID.zoneName, privacy: .private); not advancing change token; scheduling full re-sync"
                )
                markNeedsFullResync(zoneID: zoneID)
            } else {
                saveChangeToken(result.newToken, key: tokenKey)

                // Stamp freshness ONLY on the final page of a successful delta
                // pass: intermediate `moreComing` pages are incomplete, so their
                // cache must not be served by the read-first gates yet. Only
                // the types actually touched by the delta are re-stamped — the
                // other types keep their previous full-sync stamp.
                if !result.moreComing, !touchedTypes.isEmpty {
                    let stampedFamilyRecordName = resolveFamilyRecordName(familyRecordName)
                    for type in touchedTypes {
                        cacheService.markCacheFresh(familyRecordName: stampedFamilyRecordName, type: type)
                    }
                }

                if result.moreComing, pendingSync < .full {
                    pendingSync = .incremental
                }
            }

            logger.info("incrementalSync completed successfully.")
        } catch {
            if isTokenInvalidError(error) {
                logger.error("incrementalSync token invalid: \(error, privacy: .private), falling back to syncAll")
                UserDefaults.standard.removeObject(forKey: tokenKey)
                isSyncing = false
                didDelegateToFullSync = true
                await dispatchFullSync(familyRecordName: familyRecordName)
            } else {
                logger.error("incrementalSync transient failure: \(error, privacy: .private)")
                syncError = error.localizedDescription
            }
        }
    }

    private func processIncrementalChanges(_ result: CloudKitService.ZoneChangesResult) async -> Set<CachedRecordType> {
        var touchedTypes = Set<CachedRecordType>()
        for record in result.changedRecords {
            if let type = CachedRecordType.recordType(for: record.recordType) {
                touchedTypes.insert(type)
            }
            await processChangedRecord(record)
        }

        for (deletedID, recordType) in result.deletedRecordIDs {
            guard let cachedType = CachedRecordType.recordType(for: recordType) else {
                logger.warning("Skipping delete of unknown recordType '\(recordType, privacy: .public)' for record \(deletedID.recordName, privacy: .private)")
                continue
            }
            touchedTypes.insert(cachedType)
            await backgroundCache.deleteRecord(recordName: deletedID.recordName, type: cachedType)
        }
        return touchedTypes
    }

    // MARK: - Sync Helpers

    /// Derives the concrete family record name a sync is scoped to. The zone
    /// is named after the Family record, so `resolvedZoneID.zoneName` IS the
    /// family record name. A nil/empty caller scope falls back to
    /// it so stamps and purges always receive a concrete scope.
    private func resolveFamilyRecordName(_ familyRecordName: String?) -> String {
        if let familyRecordName, !familyRecordName.isEmpty {
            return familyRecordName
        }
        return cloudKit.resolvedZoneID.zoneName
    }

    /// Flags a zone for a full re-sync on the next `syncAll`/`incrementalSync`
    /// after an incremental pass hit records it could not parse. Zones are
    /// keyed by zone name, which IS the family record name.
    private func markNeedsFullResync(zoneID: CKRecordZone.ID) {
        needsFullResyncZoneNames.insert(zoneID.zoneName)
    }

    /// Records a per-sync parse failure for diagnostics. The stored set is
    /// count-limited by `maxTrackedFailedRecords` so a pathological zone cannot
    /// grow memory without bound; `failedRecordCount` stays exact and any
    /// non-zero count is the signal that the zone change token must not advance.
    private func recordParseFailure(recordName: String) {
        failedRecordCount += 1
        if failedRecordNames.count < Self.maxTrackedFailedRecords {
            failedRecordNames.insert(recordName)
        }
    }

    private func dispatchPendingSync(familyRecordName: String?) {
        guard pendingSync != .none else { return }
        let pending = pendingSync
        pendingSync = .none
        Task {
            switch pending {
            case .full, .none:
                await dispatchFullSync(familyRecordName: familyRecordName)
            case .incremental:
                await incrementalSync(familyRecordName: familyRecordName)
            }
        }
    }

    private func dispatchFullSync(familyRecordName: String?) async {
        if let familyRecordName {
            await syncAll(familyRecordName: familyRecordName)
        } else {
            await syncAllForActiveZone()
        }
    }

    private func loadChangeToken(key: String) -> CKServerChangeToken? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    private func saveChangeToken(_ token: CKServerChangeToken?, key: String) {
        guard let token,
              let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func isTokenInvalidError(_ error: Error) -> Bool {
        if let ckServiceError = error as? CloudKitServiceError {
            if case let .notFound(detail) = ckServiceError,
               detail == "15" || detail == "26" // CKError.changeTokenExpired=15, zoneNotFound=26
            {
                return true
            }
        }
        if let ckError = error as? CKError,
           ckError.code == .changeTokenExpired || ckError.code == .zoneNotFound
        {
            return true
        }
        return false
    }

    /// Returns a UserDefaults key scoped to a specific record zone and database scope.
    func tokenKey(for zoneID: CKRecordZone.ID, isShared: Bool) -> String {
        let scopeLabel = isShared ? "shared" : "private"
        return "ck_change_token.\(zoneID.zoneName).\(scopeLabel)"
    }

    func tokenKey(for zoneID: CKRecordZone.ID, db: CKDatabase?) -> String {
        let isShared = db?.databaseScope == .shared
        return tokenKey(for: zoneID, isShared: isShared)
    }

    private func processChangedRecord(_ record: CKRecord) async {
        if await processCoreRecord(record) {
            return
        }
        await processSecondaryRecord(record)
    }

    private func processCoreRecord(_ record: CKRecord) async -> Bool {
        switch record.recordType {
        case Family.recordType:
            do {
                let family = try Family(record: record)
                await backgroundCache.batchUpsertFamilies([family])
            } catch {
                logger.error("Failed to parse Family record \(record.recordID.recordName, privacy: .private): \(error)")
                recordParseFailure(recordName: record.recordID.recordName)
            }
            return true
        case Profile.recordType:
            do {
                let profile = try Profile(record: record)
                await backgroundCache.batchUpsertProfiles([profile], familyRecordName: profile.family.recordID.recordName)
            } catch {
                logger.error("Failed to parse Profile record \(record.recordID.recordName, privacy: .private): \(error)")
                recordParseFailure(recordName: record.recordID.recordName)
            }
            return true
        case Quest.recordType:
            do {
                let quest = try Quest(record: record)
                let stamped = await backgroundCache.backfillQuestNames([quest], cloudKit: cloudKit)
                await backgroundCache.batchUpsertQuests(stamped, familyRecordName: quest.family.recordID.recordName)
            } catch {
                logger.error("Failed to parse Quest record \(record.recordID.recordName, privacy: .private): \(error)")
                recordParseFailure(recordName: record.recordID.recordName)
            }
            return true
        case QuestTemplate.recordType:
            do {
                let template = try QuestTemplate(record: record)
                await backgroundCache.batchUpsertQuestTemplates([template], familyRecordName: template.family.recordID.recordName)
            } catch {
                logger.error("Failed to parse QuestTemplate record \(record.recordID.recordName, privacy: .private): \(error)")
                recordParseFailure(recordName: record.recordID.recordName)
            }
            return true
        case QuestCompletion.recordType:
            do {
                let completion = try QuestCompletion(record: record)
                await backgroundCache.batchUpsertQuestCompletions([completion], familyRecordName: completion.family.recordID.recordName)
            } catch {
                logger.error("Failed to parse QuestCompletion record \(record.recordID.recordName, privacy: .private): \(error)")
                recordParseFailure(recordName: record.recordID.recordName)
            }
            return true
        default:
            return false
        }
    }

    private func processSecondaryRecord(_ record: CKRecord) async {
        switch record.recordType {
        case LedgerEntry.recordType:
            do {
                let entry = try LedgerEntry(record: record)
                await backgroundCache.batchUpsertLedgerEntries([entry], familyRecordName: entry.family.recordID.recordName)
            } catch {
                logger.error("Failed to parse LedgerEntry record \(record.recordID.recordName, privacy: .private): \(error)")
                recordParseFailure(recordName: record.recordID.recordName)
            }
        case AllowancePeriod.recordType:
            do {
                let period = try AllowancePeriod(record: record)
                await backgroundCache.batchUpsertAllowancePeriods([period], familyRecordName: period.family.recordID.recordName)
            } catch {
                logger.error("Failed to parse AllowancePeriod record \(record.recordID.recordName, privacy: .private): \(error)")
                recordParseFailure(recordName: record.recordID.recordName)
            }
        case Achievement.recordType:
            do {
                let achievement = try Achievement(record: record)
                await backgroundCache.batchUpsertAchievements([achievement], familyRecordName: achievement.family.recordID.recordName)
            } catch {
                logger.error("Failed to parse Achievement record \(record.recordID.recordName, privacy: .private): \(error)")
                recordParseFailure(recordName: record.recordID.recordName)
            }
        case ProfileAchievement.recordType:
            do {
                let pa = try ProfileAchievement(record: record)
                await backgroundCache.batchUpsertProfileAchievements([pa], familyRecordName: pa.family.recordID.recordName)
            } catch {
                logger.error("Failed to parse ProfileAchievement record \(record.recordID.recordName, privacy: .private): \(error)")
                recordParseFailure(recordName: record.recordID.recordName)
            }
        case NotificationPreference.recordType:
            do {
                let pref = try NotificationPreference(record: record)
                await backgroundCache.batchUpsertNotificationPreferences([pref], familyRecordName: pref.family.recordID.recordName)
            } catch {
                logger.error("Failed to parse NotificationPreference record \(record.recordID.recordName, privacy: .private): \(error)")
                recordParseFailure(recordName: record.recordID.recordName)
            }
        default:
            break
        }
    }

    private func listenToPushNotifications() {
        let (stream, _) = syncCoordinator.subscribe()
        let task = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .recordChanged:
                    let familyRecordName: String? = cloudKit.activeFamilyZoneID?.zoneName
                    await incrementalSync(familyRecordName: familyRecordName)
                case let .shareAccepted(shareID):
                    let acceptedZoneID = shareID.zoneID
                    UserDefaults.standard.removeObject(forKey: tokenKey(for: acceptedZoneID, isShared: true))
                    cacheService.clearAll()
                    cloudKit.activeFamilyZoneID = acceptedZoneID
                    cloudKit.activeIsOwner = false
                    await syncAll(familyRecordName: acceptedZoneID.zoneName)
                case .zoneReset:
                    UserDefaults.standard.removeObject(forKey: tokenKey(for: cloudKit.resolvedZoneID, isShared: !cloudKit.activeIsOwner))
                    cacheService.clearAll()
                    if let familyRecordName = cloudKit.activeFamilyZoneID?.zoneName {
                        await syncAll(familyRecordName: familyRecordName)
                    } else {
                        await syncAllForActiveZone()
                    }
                }
            }
        }
        // The push listener task is stored in syncTaskMutex for cancellation in deinit.
        // The isSyncing / pendingSync mechanism serializes actual sync execution —
        // the two are distinct levels of the guardian.
        syncTaskMutex.withLock { $0 = task }
    }
}
