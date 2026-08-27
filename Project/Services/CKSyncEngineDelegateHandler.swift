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
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "LootList",
        category: "CKSyncEngineDelegateHandler"
    )

    private let cacheService: CacheService?
    private let backgroundCache: BackgroundCacheActor?
    private let conflictResolver: CKSyncConflictResolver
    private weak var appState: AppState?
    private weak var coordinator: CKSyncEngineCoordinator?
    private weak var notificationService: NotificationService?

    init(
        backgroundCache: BackgroundCacheActor? = nil,
        conflictResolver: CKSyncConflictResolver,
        cacheService: CacheService? = nil,
        appState: AppState? = nil,
        coordinator: CKSyncEngineCoordinator? = nil,
        notificationService: NotificationService? = nil
    ) {
        self.backgroundCache = backgroundCache
        self.conflictResolver = conflictResolver
        self.cacheService = cacheService
        self.appState = appState
        self.coordinator = coordinator
        self.notificationService = notificationService
    }

    func setCoordinator(_ coordinator: CKSyncEngineCoordinator) {
        self.coordinator = coordinator
        self.conflictResolver.coordinator = coordinator
    }

    func setNotificationService(_ notificationService: NotificationService) {
        self.notificationService = notificationService
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
                // WHY: CKSyncEngine retains nil pending saves forever — convert to delete only when confirmedLocalDeletion proves absence.
                let locallyDeleted = await MainActor.run {
                    RecordBridge.confirmedLocalDeletion(for: identity, cacheService: cacheService)
                }
                if locallyDeleted {
                    await MainActor.run {
                        syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                        syncEngine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
                    }
                    self.logger.warning("nextRecordZoneChangeBatch removed dangling pending save for \(recordID.recordName, privacy: .private) — enqueued delete")
                } else {
                    // WHY: A pending QuestCompletion whose row is still present must not be dropped — the nil came from validation, not deletion.
                    self.logger
                        .warning(
                            "nextRecordZoneChangeBatch suppressed dangling delete for \(recordID.recordName, privacy: .private) — local row still present, pending save retained for retry"
                        )
                }
            }
            return record
        }
    }

    // MARK: - Private Helpers

    func handleDatabaseZoneDeletion(zoneID: CKRecordZone.ID) async {
        let zoneName = zoneID.zoneName
        logger.info("Zone deleted from server: \(zoneName, privacy: .private)")
        // WHY: Zone deletion is family-scoped — purge via single background writer; watermarks remain local.
        await backgroundCache?.purgeFamily(recordName: zoneName)
        cacheService?.invalidateFreshness(forFamilyRecordName: zoneName)
        coordinator?.noteChangesProcessed()
    }

    /// Thin adapter so the CKSyncEngine delegate event path keeps its legacy
    /// optional-parameter surface while all ingestion flows through the
    /// shared pipeline below.
    func handleIncomingRecordsDirectly(
        _ records: [CKRecord],
        databaseScope: CKDatabase.Scope? = nil,
        zoneID: CKRecordZone.ID? = nil
    ) async {
        guard !records.isEmpty else { return }
        // Dual-scope is derived via databaseScope ?? (isZoneOwner ? .private : .shared).
        let scope: CKDatabase.Scope = databaseScope ?? (ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState) ? .private : .shared)
        guard let resolvedZoneID = zoneID ?? records.first?.recordID.zoneID else { return }
        await ingest(records: records, databaseScope: scope, zoneID: resolvedZoneID)
    }

    /// Single shared ingestion pipeline for inbound CKRecords. Internal —
    /// non-delegate callers (e.g. AppLifecycleCoordinator hydration passes)
    /// must reuse this exact path rather than duplicating validation or
    /// persistence, keeping one merge/save semantics across all entry points.
    ///
    /// Inbound sync validates scope and parses inbound records canonically here
    /// on MainActor into Sendable `ParsedRecord` domain models, then hands the
    /// batch to `BackgroundCacheActor.batchUpsertParsedRecords` for single-save
    /// atomic persistence. The actor's DefaultSerialModelExecutor +
    /// autosaveEnabled=false ensures the save triggers ModelContext.didSave →
    /// CacheService processPendingChanges exactly once per batch for atomic
    /// @Query visibility. Shared and private engines share this identical
    /// pipeline.
    ///
    /// - Parameter notifiesOnCompletion: Hydration/backfill passes reconcile
    ///   local state with what the server already holds; they are not
    ///   user-actionable events, so they opt out of sync notifications while
    ///   still receiving the identical parse/accounting/cache-write treatment.
    func ingest(
        records: [CKRecord],
        databaseScope: CKDatabase.Scope,
        zoneID: CKRecordZone.ID,
        notifiesOnCompletion: Bool = true
    ) async {
        // WHY: Fail-closed until family/zone resolve — dropped records re-deliver via persisted change tokens after bootstrap.
        guard let activeFamily = appState?.family?.id.recordName,
              let activeZone = appState?.familyZoneID
        else {
            logger.warning("Ingestion dropped: no active family zone — \(records.count, privacy: .public) record(s) deferred")
            return
        }

        // WHY: Caller zone must match active session zone — mismatch would poison active scope.
        guard zoneID == activeZone else {
            let callerZone = zoneID.zoneName
            let callerOwner = zoneID.ownerName
            let activeZoneName = activeZone.zoneName
            let activeOwner = activeZone.ownerName
            let deferredCount = records.count
            logger.warning(
                "Ingestion dropped: zone mismatch — caller \(callerZone, privacy: .private)/\(callerOwner, privacy: .private)"
            )
            logger.warning(
                "  != active \(activeZoneName, privacy: .private)/\(activeOwner, privacy: .private) — \(deferredCount, privacy: .public) deferred"
            )
            return
        }

        let expectedDbScope: CKDatabase.Scope = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState) ? .private : .shared

        var accepted: [ParsedRecord] = []
        var parseFailures = 0

        for record in records {
            // WHY: Identity anchored on record's own zone so cross-zone records cannot self-validate and bypass the gate.
            let identity = ScopedRecordIdentity(
                databaseScope: databaseScope,
                zoneID: record.recordID.zoneID,
                recordID: record.recordID,
                familyRecordName: activeFamily
            )

            // Fail-closed scope gate.
            // WHY: For shared participants a hero's pending completion must arrive in shared zone.
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
                continue
            }

            let parsed = ParsedRecord.parse(record: record)
            switch parsed {
            case .parseFailure:
                parseFailures += 1
                logger.error("Parse failure for incoming record: type=\(record.recordType, privacy: .public), id=\(record.recordID.recordName, privacy: .private)")
            case .ignoredSystemRecord:
                logger.debug("Ignored system record: type=\(record.recordType, privacy: .public), id=\(record.recordID.recordName, privacy: .private)")
            default:
                accepted.append(parsed)
            }
        }

        if parseFailures > 0 {
            logger.warning("Ingestion dropped: \(parseFailures) record(s) failed to parse during incoming zone changes — check CKDecodingError")
            for _ in 0 ..< parseFailures {
                coordinator?.noteParseFailure()
            }
        }

        guard !accepted.isEmpty else { return }

        guard let backgroundCache else {
            coordinator?.noteCacheWriteFailure()
            logger.error("Cache write failure during incoming zone changes")
            return
        }

        let writeSucceeded = await backgroundCache.batchUpsertParsedRecords(accepted)
        guard writeSucceeded else {
            coordinator?.noteCacheWriteFailure()
            logger.error("Cache write failure during incoming zone changes")
            return
        }

        coordinator?.noteChangesProcessed()
        if notifiesOnCompletion {
            await triggerSyncNotifications(for: accepted)
        }
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
                "Ingestion dropped: family mismatch for \(recordType, privacy: .public) \(recordName, privacy: .private)"
            )
            logger.warning(
                "  expected \(activeFamily, privacy: .private) got \(gotFamily, privacy: .private)"
            )
        } else if identity.zoneID != activeZone {
            let expectedZone = activeZone.zoneName
            let expectedOwner = activeZone.ownerName
            let gotZone = identity.zoneID.zoneName
            let gotOwner = identity.zoneID.ownerName
            let recordType = record.recordType
            let recordName = record.recordID.recordName
            logger.warning(
                "Ingestion dropped: zone mismatch for \(recordType, privacy: .public) \(recordName, privacy: .private)"
            )
            logger.warning(
                "  expected \(expectedZone, privacy: .private)/\(expectedOwner, privacy: .private)"
            )
            logger.warning(
                "  got \(gotZone, privacy: .private)/\(gotOwner, privacy: .private)"
            )
        } else if identity.databaseScope != expectedDbScope {
            let recordType = record.recordType
            let recordName = record.recordID.recordName
            let expectedScope = String(describing: expectedDbScope)
            let gotScope = String(describing: identity.databaseScope)
            logger.warning(
                "Ingestion dropped: databaseScope mismatch for \(recordType, privacy: .public) \(recordName, privacy: .private)"
            )
            logger.warning(
                "  expected \(expectedScope, privacy: .public) got \(gotScope, privacy: .public)"
            )
        } else {
            logger.warning("Ingestion dropped: scope mismatch for \(record.recordType, privacy: .public) \(record.recordID.recordName, privacy: .private)")
        }
        if record.recordType == QuestCompletion.recordType,
           expectedDbScope == .shared,
           identity.databaseScope == .private
        {
            logger.warning("QuestCompletion pending stall: shared expected .shared but got .private — dropping keeps parent stale; enqueue as isOwner:false")
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
        // WHY: questNeedsReview is parent-only per NotificationEventType.isRelevantForHero == false — never deliver to heroes even if UserDefaults was toggled.
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

    private func handleLedgerEntryNotification(_ entry: LedgerEntry, currentProfile: Profile, notificationService: NotificationService) async {
        guard entry.source == "manual_spend", currentProfile.role.isParent, entry.profile.recordID.recordName != currentProfile.id.recordName else { return }
        do {
            try await notificationService.deliverSyncNotification(
                eventType: .spendingLogged,
                title: "🪙 Spending Logged",
                body: "A hero logged spending: \(entry.description)",
                profileID: entry.profile.recordID.recordName
            )
        } catch {
            logger.error("Failed to send spendingLogged notification: \(error, privacy: .private)")
        }
    }

    private func handleIncomingZoneChanges(
        _ changes: CKSyncEngine.Event.FetchedRecordZoneChanges,
        databaseScope: CKDatabase.Scope? = nil
    ) async {
        let records = changes.modifications.map(\.record)
        let eventZoneID = records.first?.recordID.zoneID ?? changes.deletions.first?.recordID.zoneID
        await handleIncomingRecordsDirectly(records, databaseScope: databaseScope, zoneID: eventZoneID)

        // WHY: Deletion invalidation is fail-closed like ingestion — signed-out window would purge against stale scope.
        if let activeFamily = appState?.family?.id.recordName,
           let activeZone = appState?.familyZoneID
        {
            let dbScope = databaseScope ?? (ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState) ? .private : .shared)
            for deletion in changes.deletions {
                await conflictResolver.handleDeletedRecord(
                    recordID: deletion.recordID,
                    recordType: deletion.recordType,
                    databaseScope: dbScope,
                    familyRecordName: activeFamily
                )
                // WHY: Unmapped deletion types would strand stale rows — sweep all cache types (low-frequency, negligible cost).
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
            // WHY: Refresh only server-stamped system fields — preserve local optimistic edits from merge path.
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
            // WHY: Accounting reflects actual cache writes only — save failure must surface, not collapse to no-op.
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

        for failedSave in sentEvent.failedRecordSaves {
            let record = failedSave.record
            let error = failedSave.error
            let scope = syncEngine.database.databaseScope

            if let resolvedRecord = await conflictResolver.resolveFailedSave(record: record, error: error, databaseScope: scope) {
                let pendingSave = CKSyncEngine.PendingRecordZoneChange.saveRecord(resolvedRecord.recordID)
                syncEngine.state.add(pendingRecordZoneChanges: [pendingSave])
            }
        }

        // WHY: Sweep all cache types for confirmed deletes — deletions are low-frequency so full sweep has negligible cost.
        if let activeFamily = appState?.family?.id.recordName {
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

        // Handle failed deletes — log and retry
        for (recordID, error) in sentEvent.failedRecordDeletes {
            logger.error("Sent delete failed for \(recordID.recordName, privacy: .private): \(error, privacy: .private)")
            // Re-enqueue the delete for retry unless it's a permanent failure
            if error.code != .unknownItem, error.code != .zoneNotFound {
                syncEngine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
            }
        }
    }
}
