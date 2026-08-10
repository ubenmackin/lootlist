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

    private let cloudKit: any CloudKitServiceProtocol
    private let cacheService: CacheService
    private let backgroundCache: BackgroundCacheActor
    private let syncCoordinator: AppSyncCoordinator

    private(set) var isSyncing: Bool = false

    /// Priority-queued sync request when a new push notification or manual request
    /// arrives while `isSyncing` is true (`.incremental < .full`).
    /// All mutations to `pendingSync` are strictly `@MainActor`-isolated to prevent concurrent writes.
    private enum PendingSync: Comparable { case none, incremental, full }
    private var pendingSync: PendingSync = .none
    private(set) var lastSyncedAt: Date?
    var syncError: String?

    /// Zone names (== family record names) flagged for a full re-sync
    /// because a prior incremental pass hit records it could not parse.
    /// Consumed by the next `syncAll`/`incrementalSync`; never persisted across
    /// launches — the deliberately un-advanced change token already forces the
    /// full-sync fallback there.
    private(set) var needsFullResyncZoneNames: Set<String> = []

    /// Record names that failed to parse during the current incremental sync
    /// pass. The set is count-limited so a pathological zone cannot grow
    /// memory without bound; `failedRecordCount` stays exact and non-zero is
    /// the signal that the zone change token must not advance.
    private static let maxTrackedFailedRecords = 100
    private var failedRecordNames: Set<String> = []
    private var failedRecordCount = 0

    private let syncTaskMutex = Mutex<Task<Void, Never>?>(nil)

    var appState: AppState?
    var notificationService: NotificationService?

    init(cloudKit: any CloudKitServiceProtocol,
         cacheService: CacheService,
         backgroundCache: BackgroundCacheActor,
         syncCoordinator: AppSyncCoordinator,
         appState: AppState? = nil)
    {
        self.cloudKit = cloudKit
        self.cacheService = cacheService
        self.backgroundCache = backgroundCache
        self.syncCoordinator = syncCoordinator
        self.appState = appState

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
    /// deleted.
    func syncAllForActiveZone() async {
        let zoneID = cloudKit.resolvedZoneID
        let tokenKey = tokenKey(for: zoneID, isShared: !cloudKit.activeIsOwner)
        if loadChangeToken(key: tokenKey) != nil {
            await incrementalSync(familyRecordName: zoneID.zoneName)
        } else {
            await _syncAll(familyRecordName: zoneID.zoneName)
        }
    }

    /// Shared implementation for scoped full syncs.
    ///
    /// The purge path MUST always be scoped to a concrete
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

        // A prior incremental pass could not parse a record in this zone and
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
            if !Task.isCancelled {
                lastSyncedAt = Date()
                let outcome: SyncOutcome = syncErrors.isEmpty ? (recordsChanged ? .changed : .noChange) : .failed
                var userInfo: [String: Any] = [SyncOutcome.userInfoKey: outcome]
                if !syncErrors.isEmpty {
                    userInfo["errors"] = syncErrors
                }
                NotificationCenter.default.post(name: .syncDidComplete, object: self, userInfo: userInfo)
                dispatchPendingSync(familyRecordName: resolvedFamilyRecordName)
            }
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
            self.appState?.updateCurrentProfileFromCache()
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
            if Task.isCancelled || (error as? CloudKitServiceError) == .underlying("operationCancelled") || (error as? CloudKitServiceError) == .underlying("20") {
                logger.debug("Sync task cancelled for \(name, privacy: .public)")
                return
            }
            logger.error("Failed to sync \(name): \(error)")
            syncErrors.append("\(errorTag): \(error.localizedDescription)")
        }
    }

    /// Incremental delta sync using CKServerChangeToken for a specific family.
    /// Set `forceFullFetch: true` to clear the change token checkpoint and fetch
    /// all historical zone changes from scratch (e.g. during pull-to-refresh).
    func incrementalSync(familyRecordName: String? = nil, forceFullFetch: Bool = false) async {
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
            isSyncing = false
            if !didDelegateToFullSync, !Task.isCancelled {
                lastSyncedAt = Date()
                let outcome: SyncOutcome = syncError == nil ? (recordsChanged ? .changed : .noChange) : .failed
                NotificationCenter.default.post(name: .syncDidComplete, object: self, userInfo: [SyncOutcome.userInfoKey: outcome])
                Task { @MainActor [weak self] in
                    self?.appState?.updateCurrentProfileFromCache()
                }
                // After saving the change token marking byte progress, set pendingSync = incremental if moreComing.
                // The next call will resume from the checkpoint token.
                dispatchPendingSync(familyRecordName: familyRecordName)
            }
        }

        let zoneID = cloudKit.resolvedZoneID
        let tokenKey = tokenKey(for: zoneID, isShared: !cloudKit.activeIsOwner)

        if forceFullFetch {
            logger.info("forceFullFetch requested — delegating to full sync for zone \(zoneID.zoneName, privacy: .private)")
            UserDefaults.standard.removeObject(forKey: tokenKey)
            isSyncing = false
            didDelegateToFullSync = true
            await dispatchFullSync(familyRecordName: familyRecordName)
            return
        }

        // A previous incremental pass hit unparseable records in this zone,
        // so the change token was deliberately not advanced — replaying it
        // would just re-hit the same malformed records. Escalate to a full
        // re-sync, which re-reads every record and keeps them retryable.
        if needsFullResyncZoneNames.remove(zoneID.zoneName) != nil {
            logger.warning("Zone \(zoneID.zoneName, privacy: .private) flagged for full re-sync after unparseable records; running syncAll")
            isSyncing = false
            didDelegateToFullSync = true
            await _syncAll(familyRecordName: zoneID.zoneName)
            return
        }

        let token = loadChangeToken(key: tokenKey)
        logger.info("Starting incrementalSync with change token: \(token != nil ? "present" : "nil (initial)")")

        logger.info("Starting incrementalSync with change token")
        do {
            let result = try await cloudKit.fetchZoneChanges(since: token)
            recordsChanged = !result.changedRecords.isEmpty || !result.deletedRecordIDs.isEmpty
            let touchedTypes = await processIncrementalChanges(result)
            await processIncomingNotifications(result)

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

    private func processIncrementalChanges(_ result: ZoneChangesResult) async -> Set<CachedRecordType> {
        var touchedTypes = Set<CachedRecordType>()
        for parsed in result.changedRecords {
            if let type = parsed.cachedRecordType {
                touchedTypes.insert(type)
            }
            await processChangedRecord(parsed)
        }

        for (deletedID, recordType) in result.deletedRecordIDs {
            let cachedType = CachedRecordType.recordType(for: recordType)
            if let cachedType {
                touchedTypes.insert(cachedType)
            } else {
                touchedTypes.formUnion(CachedRecordType.allCases)
            }
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
        MainActor.assertIsolated()
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
        if let svcErr = error as? CloudKitServiceError {
            return svcErr == .changeTokenExpired || svcErr == .zoneNotFound
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

    /// Dispatches a pre-parsed domain model to the appropriate `backgroundCache`
    /// batch upsert. Domain parsing happened on the `@MainActor` side inside
    /// `CloudKitService+ZoneChanges`; this method only routes.
    private func processChangedRecord(_ parsed: ParsedRecord) async {
        switch parsed {
        case let .family(family):
            await backgroundCache.batchUpsertFamilies([family])
        case let .profile(profile):
            await backgroundCache.batchUpsertProfiles([profile], familyRecordName: profile.family.recordID.recordName)
        case let .quest(quest):
            let stamped = await backgroundCache.backfillQuestNames([quest], cloudKit: cloudKit)
            await backgroundCache.batchUpsertQuests(stamped, familyRecordName: quest.family.recordID.recordName)
        case let .questTemplate(template):
            await backgroundCache.batchUpsertQuestTemplates([template], familyRecordName: template.family.recordID.recordName)
        case let .questCompletion(completion):
            await backgroundCache.batchUpsertQuestCompletions([completion], familyRecordName: completion.family.recordID.recordName)
        case let .ledgerEntry(entry):
            await backgroundCache.batchUpsertLedgerEntries([entry], familyRecordName: entry.family.recordID.recordName)
        case let .allowancePeriod(period):
            await backgroundCache.batchUpsertAllowancePeriods([period], familyRecordName: period.family.recordID.recordName)
        case let .achievement(achievement):
            await backgroundCache.batchUpsertAchievements([achievement], familyRecordName: achievement.family.recordID.recordName)
        case let .profileAchievement(pa):
            await backgroundCache.batchUpsertProfileAchievements([pa], familyRecordName: pa.family.recordID.recordName)
        case let .notificationPreference(pref):
            await backgroundCache.batchUpsertNotificationPreferences([pref], familyRecordName: pref.family.recordID.recordName)
        case let .ignoredSystemRecord(recordType, recordName):
            logger.debug("Skipping system record \(recordType, privacy: .public) \(recordName, privacy: .private)")
        case let .parseFailure(recordType, recordName):
            logger.error("Skipping unparseable \(recordType, privacy: .public) record \(recordName, privacy: .private)")
            recordParseFailure(recordName: recordName)
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
                    do {
                        try cacheService.clearAll()
                    } catch {
                        logger.error("Failed to clear cache on share accept \(acceptedZoneID.zoneName, privacy: .private): \(error, privacy: .private)")
                        // A failed invalidation leaves the cache partially wiped;
                        // re-hydrating atop it could repopulate stale rows, so
                        // skip this event.
                        continue
                    }
                    cloudKit.activeFamilyZoneID = acceptedZoneID
                    cloudKit.activeIsOwner = false
                    await syncAll(familyRecordName: acceptedZoneID.zoneName)
                case .zoneReset:
                    UserDefaults.standard.removeObject(forKey: tokenKey(for: cloudKit.resolvedZoneID, isShared: !cloudKit.activeIsOwner))
                    do {
                        try cacheService.clearAll()
                    } catch {
                        logger.error("Failed to clear cache on zone reset: \(error, privacy: .private)")
                        continue
                    }
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

    // MARK: - Incoming Notification Delivery

    /// Inspects newly downloaded records from a remote sync and posts local
    /// notification banners on the receiving device for the logged-in profile.
    /// Skips records authored by the current profile to avoid self-notifications.
    private func processIncomingNotifications(_ result: ZoneChangesResult) async {
        guard let notificationService, let currentProfile = appState?.currentProfile else { return }

        for parsed in result.changedRecords {
            switch parsed {
            case let .quest(quest):
                await handleQuestNotification(quest, currentProfile: currentProfile, notificationService: notificationService)
            case let .questCompletion(completion):
                await handleQuestCompletionNotification(completion, currentProfile: currentProfile, notificationService: notificationService)
            case let .ledgerEntry(entry):
                await handleLedgerEntryNotification(entry, currentProfile: currentProfile, notificationService: notificationService)
            default:
                continue
            }
        }
    }

    private func handleQuestNotification(_ quest: Quest,
                                         currentProfile: Profile,
                                         notificationService: NotificationService) async
    {
        guard currentProfile.role == .hero else { return }
        let currentProfileName = currentProfile.id.recordName
        guard quest.assignee.recordID.recordName == currentProfileName else { return }
        let creatorName = quest.createdBy.recordID.recordName
        guard creatorName != currentProfileName else { return }

        let questTitle = quest.name ?? "a quest"
        try? await notificationService.deliverSyncNotification(
            eventType: .questAssigned,
            title: "⚔️ New Quest Assigned!",
            body: "You have been assigned '\(questTitle)'.",
            profileID: creatorName
        )
    }

    private func handleQuestCompletionNotification(_ completion: QuestCompletion,
                                                   currentProfile: Profile,
                                                   notificationService: NotificationService) async
    {
        let currentProfileName = currentProfile.id.recordName
        let completerName = completion.completedBy.recordID.recordName

        switch completion.verificationStatus {
        case .pending:
            guard currentProfile.role.isParent else { return }
            guard completerName != currentProfileName else { return }
            try? await notificationService.deliverSyncNotification(
                eventType: .questNeedsReview,
                title: "⚔️ Quest Needs Review",
                body: "A hero has completed a quest — tap to verify.",
                profileID: completerName
            )

        case .verified, .autoApproved:
            guard completerName == currentProfileName else { return }
            let verifierName = completion.verifiedBy?.recordID.recordName ?? ""
            guard verifierName != currentProfileName else { return }
            try? await notificationService.deliverSyncNotification(
                eventType: .questCompleted,
                title: "🏆 Quest Verified!",
                body: "Your quest was verified!",
                profileID: verifierName
            )

        case .rejected:
            guard completerName == currentProfileName else { return }
            let verifierName = completion.verifiedBy?.recordID.recordName ?? ""
            guard verifierName != currentProfileName else { return }
            try? await notificationService.deliverSyncNotification(
                eventType: .questRejected,
                title: "❌ Quest Rejected",
                body: "Your quest submission was not approved — check feedback and try again.",
                profileID: verifierName
            )

        case .withdrawn:
            return
        }
    }

    private func handleLedgerEntryNotification(_ entry: LedgerEntry,
                                               currentProfile: Profile,
                                               notificationService: NotificationService) async
    {
        guard currentProfile.role.isParent else { return }
        guard entry.amount < 0, entry.source == "manual" else { return }
        let currentProfileName = currentProfile.id.recordName
        let spenderName = entry.profile.recordID.recordName
        guard spenderName != currentProfileName else { return }

        let amountText = CurrencyFormatter.string(abs(entry.amount))
        try? await notificationService.deliverSyncNotification(
            eventType: .spendingLogged,
            title: "💰 Spending Logged",
            body: "A hero logged a \(amountText) purchase.",
            profileID: spenderName
        )
    }
}
