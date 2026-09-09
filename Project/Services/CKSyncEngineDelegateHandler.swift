//
//  CKSyncEngineDelegateHandler.swift
//  LootList
//
//  Created by Ben Mackin on 8/13/26.
//

import CloudKit
import Foundation
import os

@MainActor
final class CKSyncEngineDelegateHandler: CKSyncEngineDelegate {
    /// Per-type ingest result so callers stamp only zero-failure types.
    struct IngestOutcome: Sendable {
        var failedTypes: Set<CachedRecordType>
        var didCommit: Bool
        var parseFailures: Int
        var committedTypes: Set<CachedRecordType> = []
    }

    /// Filtered ingest batch bundled to stay within the large_tuple limit.
    private struct ProcessedIngestRecords: Sendable {
        var accepted: [ParsedRecord]
        var parseFailures: Int
        var failedTypes: Set<CachedRecordType>
        var dropped: Int
    }

    private let logger = Logger(category: "CKSyncEngineDelegateHandler")

    private let cacheService: CacheService?
    private var backgroundCache: BackgroundCacheActor?
    private let conflictResolver: CKSyncConflictResolver
    private weak var appState: AppState?
    private weak var coordinator: CKSyncEngineCoordinator?
    private weak var notificationService: NotificationService?
    private weak var toastManager: ToastManager?

    /// Test-visible hydration accounting for single-save batch verification.
    var hydrateCallCount = 0

    #if DEBUG
        var lastDiscardedSaveDiagnostic: String?
    #endif

    init(
        backgroundCache: BackgroundCacheActor? = nil,
        conflictResolver: CKSyncConflictResolver,
        cacheService: CacheService? = nil,
        appState: AppState? = nil,
        coordinator: CKSyncEngineCoordinator? = nil,
        notificationService: NotificationService? = nil,
        toastManager: ToastManager? = nil
    ) {
        self.backgroundCache = backgroundCache
        self.conflictResolver = conflictResolver
        if let backgroundCache {
            self.conflictResolver.setBackgroundCache(backgroundCache)
        }
        self.cacheService = cacheService
        self.appState = appState
        self.coordinator = coordinator
        self.notificationService = notificationService
        self.toastManager = toastManager
    }

    func setToastManager(_ toastManager: ToastManager) {
        self.toastManager = toastManager
    }

    func setCoordinator(_ coordinator: CKSyncEngineCoordinator) {
        self.coordinator = coordinator
        self.conflictResolver.coordinator = coordinator
    }

    func setNotificationService(_ notificationService: NotificationService) {
        self.notificationService = notificationService
    }

    func setBackgroundCache(_ backgroundCache: BackgroundCacheActor) {
        self.backgroundCache = backgroundCache
        self.conflictResolver.setBackgroundCache(backgroundCache)
    }

    // MARK: - CKSyncEngineDelegate Event Handling

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case let .stateUpdate(stateEvent):
            let serialization = stateEvent.stateSerialization
            let scope = syncEngine.database.databaseScope
            coordinator?.saveState(serialization, for: scope)

        case let .accountChange(accountEvent):
            await handleAccountChange(changeType: accountEvent.changeType)

        case let .fetchedDatabaseChanges(dbChanges):
            for deletion in dbChanges.deletions {
                await handleDatabaseZoneDeletion(zoneID: deletion.zoneID)
            }

        case let .fetchedRecordZoneChanges(zoneChanges):
            await handleIncomingZoneChanges(zoneChanges, databaseScope: syncEngine.database.databaseScope)

        case let .sentRecordZoneChanges(sentEvent):
            await handleSentRecordZoneChanges(sentEvent, syncEngine: syncEngine)

        case .willSendChanges, .didSendChanges, .willFetchChanges, .didFetchChanges:
            handleSyncLifecycleEvent(event)

        case .willFetchRecordZoneChanges, .didFetchRecordZoneChanges, .sentDatabaseChanges:
            break

        @unknown default:
            logger.warning("Received unknown CKSyncEngine event: \(String(describing: event))")
        }
    }

    func handleAccountChange(changeType: CKSyncEngine.Event.AccountChange.ChangeType) async {
        logger.info("iCloud account change received: \(String(describing: changeType))")
        switch changeType {
        case .signOut, .switchAccounts:
            let hasActiveSession: Bool = if let appState {
                switch appState.authStatus {
                case .authenticated, .detectedPreviousFamily:
                    true
                default:
                    appState.currentProfile != nil
                        && appState.family != nil
                        && appState.familyZoneID != nil
                }
            } else {
                false
            }
            guard hasActiveSession else {
                logger.info("Ignoring duplicate account transition without an active session")
                return
            }
            let oldAccountID = appState?.currentProfile?.id.recordName ?? appState?.family?.id.recordName
            coordinator?.resetState(forAccountID: oldAccountID)
            if let cloudKit = coordinator?.cloudKitService {
                await appState?.signOutAndDiscover(cloudKit: cloudKit, syncCoordinator: coordinator)
            } else {
                appState?.clearSession()
            }
        case .signIn:
            guard appState?.authStatus == .checkingCloudData,
                  let cloudKit = coordinator?.cloudKitService
            else {
                logger.info("Ignoring sign-in callback outside the discovery state")
                return
            }
            await appState?.discoverExistingCloudState(cloudKit: cloudKit)
        @unknown default:
            break
        }
    }

    private func handleSyncLifecycleEvent(_ event: CKSyncEngine.Event) {
        // Lifecycle event logging; coordinator exclusively owns isSyncing state across passes.
        logger.debug("Sync lifecycle event: \(String(describing: event))")
    }

    // MARK: - Batch Provider for Sending Changes

    func nextRecordZoneChangeBatch(
        _: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges
        guard !pending.isEmpty else { return nil }

        guard let activeFamily = appState?.family?.id.recordName else {
            logger.warning("nextRecordZoneChangeBatch aborted: no active family scope")
            return nil
        }
        let dbScope = syncEngine.database.databaseScope
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [weak self] recordID in
            guard let self, let cacheService = self.cacheService else { return nil }
            let identity = ScopedRecordIdentity(
                databaseScope: dbScope,
                zoneID: recordID.zoneID,
                recordID: recordID,
                familyRecordName: activeFamily
            )
            let record = await MainActor.run {
                RecordBridge.record(for: identity, cacheService: cacheService)
            }
            if record == nil {
                // If confirmed locally deleted, convert pending save to a delete.
                let locallyDeleted = await MainActor.run {
                    RecordBridge.confirmedLocalDeletion(for: identity, cacheService: cacheService)
                }
                if locallyDeleted {
                    await MainActor.run {
                        syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                        syncEngine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
                        self.coordinator?.clearRetryState(for: recordID)
                    }
                    self.logger.warning("nextRecordZoneChangeBatch removed dangling pending save for \(recordID.recordName, privacy: .private) — enqueued delete")
                } else {
                    // WHY: `locallyDeleted == false` is ambiguous — row still present (retain)
                    // or fetch threw (unknown stall); distinguish via fetchSucceeded
                    // so unknown does not spin indefinitely.
                    let fetchSucceeded = await MainActor.run {
                        RecordBridge.fetchSucceeded(for: identity, cacheService: cacheService)
                    }
                    if !fetchSucceeded {
                        // WHY: transient ModelContext fetch failure — do NOT drop save nor convert to delete; log and schedule retry with exponential backoff and 30s deadline to avoid tight spin.
                        self.logger
                            .warning(
                                "nextRecordZoneChangeBatch fetch error for \(recordID.recordName, privacy: .private) — verification failed, pending save retained for retry with 30s deadline"
                            )
                        let isOwner = identity.databaseScope == .private
                        await MainActor.run {
                            self.coordinator?.scheduleRetry(for: recordID, isOwner: isOwner)
                        }
                    } else {
                        self.logger
                            .warning(
                                "nextRecordZoneChangeBatch suppressed dangling delete for \(recordID.recordName, privacy: .private) — local row still present, pending save retained for retry"
                            )
                    }
                }
            } else {
                await MainActor.run {
                    self.coordinator?.clearRetryState(for: recordID)
                }
            }
            return record
        }
    }

    // MARK: - Private Helpers

    func handleDatabaseZoneDeletion(zoneID: CKRecordZone.ID) async {
        let zoneName = zoneID.zoneName
        logger.info("Zone deleted from server: \(zoneName, privacy: .private)")
        await backgroundCache?.purgeFamily(recordName: zoneName)
        cacheService?.invalidateFreshness(forFamilyRecordName: zoneName)
        coordinator?.noteChangesProcessed()
    }

    /// Thin adapter for CKSyncEngine delegate surface; all ingestion flows through shared pipeline.
    @discardableResult
    func handleIncomingRecordsDirectly(
        _ records: [CKRecord],
        databaseScope: CKDatabase.Scope? = nil,
        zoneID: CKRecordZone.ID? = nil
    ) async -> IngestOutcome? {
        guard !records.isEmpty else { return nil }
        // WHY fail-closed scope: unknown scope drops so caller zone re-delivers via tokens.
        guard let scope = databaseScope ?? DatabaseScopeResolver.resolvedScope(appState: appState) else {
            logger.warning("Ingestion dropped: unknown database scope — \(records.count, privacy: .public) record(s) deferred")
            return nil
        }
        guard let resolvedZoneID = zoneID ?? records.first?.recordID.zoneID else { return nil }
        return await ingest(records: records, databaseScope: scope, zoneID: resolvedZoneID)
    }

    /// Central inbound ingestion entry — all server→cache writes ride this method.
    @discardableResult
    func ingest(
        records: [CKRecord],
        databaseScope: CKDatabase.Scope,
        zoneID: CKRecordZone.ID,
        notifiesOnCompletion: Bool = true
    ) async -> IngestOutcome? {
        // Fails closed if family zone is unresolved to avoid cross-scope pollution.
        guard let activeFamily = appState?.family?.id.recordName,
              let activeZone = appState?.familyZoneID
        else {
            logger.warning("Ingestion dropped: no active family zone — \(records.count, privacy: .public) record(s) deferred")
            return nil
        }

        guard zoneID == activeZone else {
            let callerZone = zoneID.zoneName
            let callerOwner = zoneID.ownerName
            let activeZoneName = activeZone.zoneName
            let activeOwner = activeZone.ownerName
            let deferredCount = records.count
            logger.warning(
                "Ingestion dropped: zone mismatch caller \(callerZone)/\(callerOwner) != active \(activeZoneName)/\(activeOwner) deferred \(deferredCount)",
                family: activeFamily,
                zone: activeZone.zoneName
            )
            return nil
        }

        // WHY unknown scope fails closed: defaulting to .shared risks cross-scope pollution.
        guard let expectedDbScope = DatabaseScopeResolver.resolvedScope(appState: appState) else {
            logger.warning(
                "Ingestion dropped: unknown database scope — \(records.count) record(s) deferred",
                family: activeFamily,
                zone: activeZone.zoneName
            )
            return nil
        }
        let processed = processIngestRecords(
            records,
            databaseScope: databaseScope,
            expectedDbScope: expectedDbScope,
            activeFamily: activeFamily,
            activeZone: activeZone
        )
        let accepted = processed.accepted
        let parseFailures = processed.parseFailures
        let failedTypes = processed.failedTypes
        let dropped = processed.dropped

        if parseFailures > 0 {
            logger.warning(
                "Ingestion dropped: \(parseFailures) record(s) failed to parse during incoming zone changes — check CKDecodingError",
                family: activeFamily,
                zone: activeZone.zoneName
            )
            for _ in 0 ..< parseFailures {
                coordinator?.noteParseFailure()
            }
        }

        // WHY watermarks mean rows committed: empty batch with drops must not stamp fresh.
        guard !accepted.isEmpty else {
            let hasFailures = parseFailures > 0 || dropped > 0
            return IngestOutcome(failedTypes: failedTypes, didCommit: !hasFailures, parseFailures: parseFailures, committedTypes: [])
        }

        var writer = backgroundCache ?? appState?.backgroundCacheActor ?? cacheService?.backgroundWriter
        if writer == nil, let cache = cacheService {
            await cache.bootstrapBackgroundWriterIfNeeded()
            writer = cache.backgroundWriter
            if let writer {
                setBackgroundCache(writer)
            }
        }
        guard let writer else {
            coordinator?.noteCacheWriteFailure()
            logger.error("Cache write failure during incoming zone changes: no BackgroundCacheActor available")
            return IngestOutcome(failedTypes: failedTypes, didCommit: false, parseFailures: parseFailures, committedTypes: [])
        }

        let writeSucceeded = await writer.batchUpsertParsedRecords(accepted)
        guard writeSucceeded else {
            coordinator?.noteCacheWriteFailure()
            logger.error("Cache write failure during incoming zone changes: batch upsert failed")
            return IngestOutcome(failedTypes: failedTypes, didCommit: false, parseFailures: parseFailures, committedTypes: [])
        }

        coordinator?.noteChangesProcessed()
        if notifiesOnCompletion {
            await triggerSyncNotifications(for: accepted)
        }
        // WHY committed set gates stamping: only types with rows written may stamp fresh.
        let committedTypes = Set(accepted.compactMap(\.cachedRecordType))
        return IngestOutcome(failedTypes: failedTypes, didCommit: true, parseFailures: parseFailures, committedTypes: committedTypes)
    }

    private func processIngestRecords(
        _ records: [CKRecord],
        databaseScope: CKDatabase.Scope,
        expectedDbScope: CKDatabase.Scope,
        activeFamily: String,
        activeZone: CKRecordZone.ID
    ) -> ProcessedIngestRecords {
        var accepted: [ParsedRecord] = []
        var parseFailures = 0
        var failedTypes: Set<CachedRecordType> = []
        var dropped = 0
        for record in records {
            let identity = ScopedRecordIdentity(
                databaseScope: databaseScope,
                zoneID: record.recordID.zoneID,
                recordID: record.recordID,
                familyRecordName: activeFamily
            )

            // Fail-closed scope gate.
            if !identity.matchesActiveScope(
                expectedFamily: activeFamily,
                expectedZone: activeZone,
                expectedDatabase: expectedDbScope
            ) {
                logIngestScopeMismatch(
                    record: record,
                    identity: identity,
                    activeFamily: activeFamily,
                    activeZone: activeZone,
                    expectedDbScope: expectedDbScope
                )
                // WHY dropped types gate stamping: zero committed rows must stay stale.
                dropped += 1
                if let droppedType = CachedRecordType.recordType(for: record.recordType) {
                    failedTypes.insert(droppedType)
                }
                continue
            }

            let parsed = ParsedRecord.parse(record: record)
            switch parsed {
            case .parseFailure:
                parseFailures += 1
                // WHY: unknown record types carry no freshness watermark, so only known types gate per-type stamping.
                if let failedType = CachedRecordType.recordType(for: record.recordType) {
                    failedTypes.insert(failedType)
                }
                logger.error("Parse failure for incoming record: type=\(record.recordType, privacy: .public), id=\(record.recordID.recordName, privacy: .private)")
            case .ignoredSystemRecord:
                logger.debug("Ignored system record: type=\(record.recordType, privacy: .public), id=\(record.recordID.recordName, privacy: .private)")
            default:
                checkTransferSkew(record: record, parsed: parsed)
                accepted.append(parsed)
            }
        }
        return ProcessedIngestRecords(accepted: accepted, parseFailures: parseFailures, failedTypes: failedTypes, dropped: dropped)
    }

    private func checkTransferSkew(record: CKRecord, parsed: ParsedRecord) {
        guard case let .ledgerEntry(entry) = parsed, entry.sourceEnum == .transfer else { return }
        let serverDate: Date? = record.creationDate ?? {
            let data = record.encodedSystemFields
            guard !data.isEmpty else { return nil }
            do {
                return try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: data)?.creationDate
            } catch {
                logger.warning("CKRecord systemFields decode failed for \(record.recordID.recordName, privacy: .private): \(error, privacy: .private)")
                return nil
            }
        }()
        guard let serverDate else { return }
        WeekMath.logTransferSkewIfNeeded(localDate: entry.date, serverDate: serverDate)
    }

    private func logIngestScopeMismatch(
        record: CKRecord,
        identity: ScopedRecordIdentity,
        activeFamily: String,
        activeZone: CKRecordZone.ID,
        expectedDbScope: CKDatabase.Scope
    ) {
        if identity.familyRecordName != activeFamily {
            let recordType = record.recordType
            let recordName = record.recordID.recordName
            let gotFamily = identity.familyRecordName ?? "nil"
            logger.warning(
                "Ingestion dropped: family mismatch for \(recordType) \(recordName) expected \(activeFamily) got \(gotFamily)",
                family: activeFamily,
                zone: activeZone.zoneName
            )
        } else if identity.zoneID != activeZone {
            let expectedZone = activeZone.zoneName
            let expectedOwner = activeZone.ownerName
            let gotZone = identity.zoneID.zoneName
            let gotOwner = identity.zoneID.ownerName
            let recordType = record.recordType
            let recordName = record.recordID.recordName
            logger.warning(
                "Ingestion dropped: zone mismatch for \(recordType) \(recordName) expected \(expectedZone)/\(expectedOwner) got \(gotZone)/\(gotOwner)",
                family: activeFamily,
                zone: activeZone.zoneName
            )
        } else if identity.databaseScope != expectedDbScope {
            let recordType = record.recordType
            let recordName = record.recordID.recordName
            let expectedScope = String(describing: expectedDbScope)
            let gotScope = String(describing: identity.databaseScope)
            logger.warning(
                "Ingestion dropped: databaseScope mismatch for \(recordType) \(recordName) expected \(expectedScope) got \(gotScope)",
                family: activeFamily,
                zone: activeZone.zoneName
            )
        } else {
            logger.warning(
                "Ingestion dropped: scope mismatch for \(record.recordType) \(record.recordID.recordName)",
                family: activeFamily,
                zone: activeZone.zoneName
            )
        }
        if record.recordType == QuestCompletion.recordType,
           expectedDbScope == .shared,
           identity.databaseScope == .private
        {
            logger.warning(
                "QuestCompletion pending stall: shared expected .shared but got .private — dropping keeps parent stale; enqueue as isOwner:false",
                family: activeFamily,
                zone: activeZone.zoneName
            )
        }
    }

    private func triggerSyncNotifications(for records: [ParsedRecord]) async {
        guard let notificationService, let currentProfile = appState?.currentProfile else { return }
        for parsed in records {
            switch parsed {
            case let .quest(quest):
                await handleQuestNotification(quest, currentProfile: currentProfile, notificationService: notificationService)
            case let .questCompletion(completion):
                await handleQuestCompletionNotification(completion, currentProfile: currentProfile, notificationService: notificationService)
            case let .ledgerEntry(entry):
                await handleLedgerEntryNotification(entry, currentProfile: currentProfile, notificationService: notificationService)
            default:
                break
            }
        }
    }

    private func handleQuestNotification(_ quest: Quest, currentProfile: Profile, notificationService: NotificationService) async {
        guard quest.assignee.recordID.recordName == currentProfile.id.recordName, quest.active else { return }
        do {
            try await notificationService.deliverSyncNotification(
                eventType: .questAssigned,
                title: "⚔️ New Quest Assigned",
                body: "\(quest.name ?? "A quest") has been assigned to you!",
                profileID: quest.createdBy.recordID.recordName
            )
        } catch {
            logger.error("Failed to send questAssigned notification: \(error, privacy: .private)")
        }
    }

    private func handleQuestCompletionNotification(_ completion: QuestCompletion, currentProfile: Profile, notificationService: NotificationService) async {
        let completerName = completion.completedBy.recordID.recordName
        if completion.verificationStatus == .pending, currentProfile.role.isParent {
            await deliverQuestNeedsReview(completerName: completerName, notificationService: notificationService)
        } else if completion.verificationStatus == .verified, completerName == currentProfile.id.recordName {
            await deliverQuestApproved(completion: completion, completerName: completerName, notificationService: notificationService)
        } else if completion.verificationStatus == .rejected, completerName == currentProfile.id.recordName {
            await deliverQuestRejected(completion: completion, completerName: completerName, notificationService: notificationService)
        }
    }

    private func deliverQuestNeedsReview(completerName: String, notificationService: NotificationService) async {
        do {
            try await notificationService.deliverSyncNotification(
                eventType: .questNeedsReview,
                title: "⚔️ Quest Needs Review",
                body: "A hero has completed a quest — tap to review.",
                profileID: completerName
            )
        } catch {
            logger.error("Failed to send questNeedsReview notification: \(error, privacy: .private)")
        }
    }

    private func deliverQuestApproved(completion: QuestCompletion, completerName: String, notificationService: NotificationService) async {
        do {
            try await notificationService.deliverSyncNotification(
                eventType: .questCompleted,
                title: "🎉 Quest Approved!",
                body: "Your quest submission was verified and approved!",
                profileID: completion.verifiedBy?.recordID.recordName ?? completerName
            )
        } catch {
            logger.error("Failed to send questCompleted notification: \(error, privacy: .private)")
        }
    }

    private func deliverQuestRejected(completion: QuestCompletion, completerName: String, notificationService: NotificationService) async {
        do {
            try await notificationService.deliverSyncNotification(
                eventType: .questRejected,
                title: "❌ Quest Rejected",
                body: "Your quest submission was not approved — check feedback and try again.",
                profileID: completion.verifiedBy?.recordID.recordName ?? completerName
            )
        } catch {
            logger.error("Failed to send questRejected notification: \(error, privacy: .private)")
        }
    }

    /// WHY daily-rollup: per-spend buzz is retired — spends batch into the 9am digest so parents get one rollup, not a buzz per purchase.
    private func handleLedgerEntryNotification(_: LedgerEntry, currentProfile _: Profile, notificationService _: NotificationService) async {}

    /// CKSyncEngine fetchedRecordZoneChanges entry point → handleIncomingRecordsDirectly → ingest.
    private func handleIncomingZoneChanges(
        _ changes: CKSyncEngine.Event.FetchedRecordZoneChanges,
        databaseScope: CKDatabase.Scope? = nil
    ) async {
        let records = changes.modifications.map(\.record)
        let eventZoneID = records.first?.recordID.zoneID ?? changes.deletions.first?.recordID.zoneID
        await handleIncomingRecordsDirectly(records, databaseScope: databaseScope, zoneID: eventZoneID)
        coordinator?.notePushReceived()

        if let activeFamily = appState?.family?.id.recordName,
           let activeZone = appState?.familyZoneID
        {
            // WHY fail-closed scope: unknown scope drops deletes so wrong-scope purge cannot run.
            guard let dbScope = databaseScope ?? DatabaseScopeResolver.resolvedScope(appState: appState) else {
                logger.warning("Deletions dropped: unknown database scope — \(changes.deletions.count, privacy: .public) deletion(s) deferred")
                return
            }
            for deletion in changes.deletions {
                await conflictResolver.handleDeletedRecord(
                    recordID: deletion.recordID,
                    recordType: deletion.recordType,
                    databaseScope: dbScope,
                    familyRecordName: activeFamily
                )
                guard CachedRecordType.recordType(for: deletion.recordType) == nil else { continue }
                let identity = ScopedRecordIdentity(
                    databaseScope: dbScope,
                    zoneID: deletion.recordID.zoneID,
                    recordID: deletion.recordID,
                    familyRecordName: activeFamily
                )
                for type in CachedRecordType.allCases {
                    await backgroundCache?.deleteByIdentity(identity, type: type, expectedActiveZone: activeZone)
                }
            }
        }
        if !changes.deletions.isEmpty {
            coordinator?.noteChangesProcessed()
        }
    }

    private func handleSentRecordZoneChanges(
        _ sentEvent: CKSyncEngine.Event.SentRecordZoneChanges,
        syncEngine: CKSyncEngine
    ) async {
        if let activeFamily = appState?.family?.id.recordName {
            checkSentTransferSkew(sentEvent, activeFamily: activeFamily)
            await refreshSentSystemFields(sentEvent, activeFamily: activeFamily)
        }
        await resolveFailedSaves(sentEvent, syncEngine: syncEngine)
        await processSentDeletes(sentEvent, syncEngine: syncEngine)
        processFailedDeletes(sentEvent, syncEngine: syncEngine)
    }

    private func checkSentTransferSkew(
        _ sentEvent: CKSyncEngine.Event.SentRecordZoneChanges,
        activeFamily: String
    ) {
        for savedRecord in sentEvent.savedRecords where savedRecord.recordType == LedgerEntry.recordType {
            guard let source = savedRecord["source"] as? String, LedgerSource(rawValue: source) == .transfer else { continue }
            let localDate: Date? = (savedRecord["date"] as? Date) ?? cacheService?.fetchLedgerEntry(recordName: savedRecord.recordID.recordName, family: activeFamily)?.date
            guard let localDate else { continue }
            let serverDate: Date? = savedRecord.creationDate ?? {
                let data = savedRecord.encodedSystemFields
                guard !data.isEmpty else { return nil }
                do {
                    return try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: data)?.creationDate
                } catch {
                    logger.warning("CKRecord systemFields decode failed for \(savedRecord.recordID.recordName, privacy: .private): \(error, privacy: .private)")
                    return nil
                }
            }()
            guard let serverDate else { continue }
            WeekMath.logTransferSkewIfNeeded(localDate: localDate, serverDate: serverDate)
        }
    }

    private func refreshSentSystemFields(
        _ sentEvent: CKSyncEngine.Event.SentRecordZoneChanges,
        activeFamily: String
    ) async {
        let refreshes = sentEvent.savedRecords.compactMap { savedRecord -> SystemFieldRefresh? in
            guard let type = CachedRecordType.recordType(for: savedRecord.recordType) else {
                logger.debug("Skipping sent saved record with unmappable type: \(savedRecord.recordType, privacy: .public)")
                return nil
            }
            return SystemFieldRefresh(
                recordName: savedRecord.recordID.recordName,
                type: type,
                changeTag: savedRecord.recordChangeTag,
                encodedSystemFields: savedRecord.encodedSystemFields
            )
        }
        switch await backgroundCache?.updateSystemFields(refreshes, familyRecordName: activeFamily) ?? .noMatches {
        case .updated:
            coordinator?.noteChangesProcessed()
        case .noMatches:
            break
        case .saveFailed:
            logger.error("Post-send system-field refresh failed to commit for \(refreshes.count, privacy: .private) record(s)")
            coordinator?.noteCacheWriteFailure()
        }
    }

    private func resolveFailedSaves(
        _ sentEvent: CKSyncEngine.Event.SentRecordZoneChanges,
        syncEngine: CKSyncEngine
    ) async {
        for failedSave in sentEvent.failedRecordSaves {
            let record = failedSave.record
            let error = failedSave.error
            let scope = syncEngine.database.databaseScope
            if let resolvedRecord = await conflictResolver.resolveFailedSave(record: record, error: error, databaseScope: scope) {
                let pendingSave = CKSyncEngine.PendingRecordZoneChange.saveRecord(resolvedRecord.recordID)
                syncEngine.state.add(pendingRecordZoneChanges: [pendingSave])
            } else {
                // WHY: pending save was rejected and not re-enqueued — surface the discard so optimistic UI does not silently flip.
                let isServerRecordChanged = error.code == .serverRecordChanged
                let isSecondary = CachedRecordType.recordType(for: record.recordType).map { type in
                    ![CachedRecordType.quest, .profile, .questCompletion, .allowancePeriod].contains(type)
                } ?? false
                // Secondary server-wins already toasted inside resolver; avoid duplicate banner for that exact path.
                if isServerRecordChanged, isSecondary {
                    continue
                }
                let familyForStale: String? = appState?.family?.id.recordName
                    ?? (record["family"] as? CKRecord.Reference)?.recordID.recordName
                if let familyForStale, let staleType = CachedRecordType.recordType(for: record.recordType) {
                    cacheService?.invalidateFreshness(familyRecordName: familyForStale, type: staleType)
                } else if familyForStale == nil,
                          let staleType = CachedRecordType.recordType(for: record.recordType)
                {
                    let typeLabel = String(describing: staleType)
                    let recordName = record.recordID.recordName
                    logger.fault(
                        "Could not resolve family for stale invalidation — skipping freshness invalidation for \(typeLabel, privacy: .public) id=\(recordName, privacy: .private)"
                    )
                }
                let message = discardedSaveMessage(for: record)
                logDiscardedSave(record: record, error: error, scope: scope)
                toastManager?.show(message: message, type: .warning)
            }
        }
    }

    func discardedSaveMessage(for record: CKRecord) -> String {
        LedgerRevertMessage.saveFailedMessage(
            for: CachedRecordType.recordType(for: record.recordType),
            sourceRawValue: record["source"] as? String
        )
    }

    func discardedSaveDiagnostic(for record: CKRecord, error: CKError, scope: CKDatabase.Scope) -> String {
        let nsError = error as NSError
        return LedgerRevertMessage.saveFailureDiagnostic(
            record: record,
            codeValue: error.code.rawValue,
            codeLabel: String(describing: error.code),
            domain: nsError.domain,
            description: error.localizedDescription,
            scopeLabel: String(describing: scope),
            serverRecordPresent: error.serverRecord != nil
        )
    }

    private func logDiscardedSave(record: CKRecord, error: CKError, scope: CKDatabase.Scope) {
        let diagnostic = discardedSaveDiagnostic(for: record, error: error, scope: scope)
        logger.error("Discarded save \(diagnostic, privacy: .private)")
        #if DEBUG
            lastDiscardedSaveDiagnostic = diagnostic
        #endif
    }

    private func processSentDeletes(
        _ sentEvent: CKSyncEngine.Event.SentRecordZoneChanges,
        syncEngine: CKSyncEngine
    ) async {
        guard let activeFamily = appState?.family?.id.recordName else { return }
        let scope = syncEngine.database.databaseScope
        let activeZone = appState?.familyZoneID
        for deletedRecordID in sentEvent.deletedRecordIDs {
            logger.info("Sent delete confirmed: \(deletedRecordID.recordName, privacy: .private)")
            let identity = ScopedRecordIdentity(
                databaseScope: scope,
                zoneID: deletedRecordID.zoneID,
                recordID: deletedRecordID,
                familyRecordName: activeFamily
            )
            for type in CachedRecordType.allCases {
                await backgroundCache?.deleteByIdentity(identity, type: type, expectedActiveZone: activeZone)
            }
            coordinator?.noteChangesProcessed()
        }
    }

    private func processFailedDeletes(
        _ sentEvent: CKSyncEngine.Event.SentRecordZoneChanges,
        syncEngine: CKSyncEngine
    ) {
        for (recordID, error) in sentEvent.failedRecordDeletes {
            logger.error("Sent delete failed for \(recordID.recordName, privacy: .private): \(error, privacy: .private)")
            // Re-enqueue the delete for retry unless it's a permanent failure
            if error.code != .unknownItem, error.code != .zoneNotFound {
                syncEngine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
            }
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
