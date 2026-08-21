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

    func setAppState(_ appState: AppState) {
        self.appState = appState
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
                // Dangling pending fix: the underlying *Cache may have been
                // deleted after enqueueSave but before transmission, and
                // CKSyncEngine retains pendingRecordZoneChanges forever if we
                // keep returning nil. A nil bridge alone does NOT prove local
                // deletion — family or database-scope validation can also fail
                // (e.g. locally-created rows never hydrated with
                // sourceDatabaseScope). Enqueue a server-side delete only when
                // no cached row exists for the record name at all; otherwise
                // drop just the stale save so a live cloud record is never
                // destroyed.
                let locallyDeleted = await MainActor.run {
                    RecordBridge.confirmedLocalDeletion(for: identity, cacheService: cacheService)
                }
                await MainActor.run {
                    syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
                    if locallyDeleted {
                        syncEngine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
                    }
                }
                if locallyDeleted {
                    self.logger.warning("nextRecordZoneChangeBatch removed dangling pending save for \(recordID.recordName, privacy: .private) — enqueued delete")
                } else {
                    self.logger
                        .warning("nextRecordZoneChangeBatch removed stale pending save for \(recordID.recordName, privacy: .private) — local row still present, delete suppressed")
                }
            }
            return record
        }
    }

    // MARK: - Private Helpers

    func handleDatabaseZoneDeletion(zoneID: CKRecordZone.ID) async {
        let zoneName = zoneID.zoneName
        logger.info("Zone deleted from server: \(zoneName, privacy: .private)")
        // A whole family zone was removed server-side (owner revoked the
        // zone or the family was deleted). Purge the matching family's
        // cached rows on both background and main caches so no stale rows survive.
        await backgroundCache?.purgeFamily(recordName: zoneName)
        cacheService?.purgeFamily(recordName: zoneName)
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
        let scope: CKDatabase.Scope = databaseScope ?? ((appState?.isZoneOwner == true) ? .private : .shared)
        guard let resolvedZoneID = zoneID ?? records.first?.recordID.zoneID else { return }
        await ingest(records: records, databaseScope: scope, zoneID: resolvedZoneID)
    }

    /// Single shared ingestion pipeline for inbound CKRecords. Internal —
    /// non-delegate callers (e.g. AppLifecycleCoordinator hydration passes)
    /// must reuse this exact path rather than duplicating validation or
    /// persistence, keeping one merge/save semantics across all entry points.
    ///
    /// Inbound sync is off-main: scope values resolve here on MainActor, then
    /// a single actor call hands the batch to BackgroundCacheActor inside a
    /// Sendable box for parsing, validation, and batched single-save
    /// persistence. The actor's DefaultSerialModelExecutor +
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
        // Fail closed until the active family and zone resolve: engine state persists server-side change tokens, so records dropped here re-deliver on the next delta fetch after
        // bootstrap completes.
        guard let activeFamily = appState?.family?.id.recordName,
              let activeZone = appState?.familyZoneID
        else {
            logger.warning("Ingestion deferred without an active family zone: \(records.count, privacy: .public) record(s) dropped")
            return
        }

        // The caller-declared zone must agree with the session's own active
        // zone; they resolve from independent sources, so disagreement means
        // the batch belongs to a family context other than the live session
        // and writing it would poison the active scope.
        guard zoneID == activeZone else {
            logger.warning("Ingestion deferred: caller zone does not match the active family zone: \(records.count, privacy: .public) record(s) dropped")
            return
        }

        guard let backgroundCache else {
            coordinator?.noteCacheWriteFailure()
            logger.error("Cache write failure during incoming zone changes")
            return
        }

        let outcome = await backgroundCache.parseAndUpsert(
            records: IncomingRecordBatch(records: records),
            expectedScope: databaseScope,
            familyRecordName: activeFamily,
            activeZone: activeZone,
            isZoneOwner: appState?.isZoneOwner == true
        )

        if outcome.parseFailures > 0 {
            logger.warning("\(outcome.parseFailures) record(s) failed to parse during incoming zone changes")
            for _ in 0 ..< outcome.parseFailures {
                coordinator?.noteParseFailure()
            }
        }

        guard outcome.writeSucceeded else {
            coordinator?.noteCacheWriteFailure()
            logger.error("Cache write failure during incoming zone changes")
            return
        }

        if !outcome.acceptedRecords.isEmpty {
            coordinator?.noteChangesProcessed()
            if notifiesOnCompletion {
                await triggerSyncNotifications(for: outcome.acceptedRecords)
            }
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

        // Deletion invalidation is gated on the same fail-closed session check
        // as ingestion: applying deletions during a signed-out window would
        // purge rows against a stale family scope.
        if let activeFamily = appState?.family?.id.recordName,
           appState?.familyZoneID != nil
        {
            let dbScope = databaseScope ?? ((appState?.isZoneOwner == true) ? .private : .shared)
            for deletion in changes.deletions {
                await conflictResolver.handleDeletedRecord(
                    recordID: deletion.recordID,
                    recordType: deletion.recordType,
                    databaseScope: dbScope,
                    familyRecordName: activeFamily
                )
                // Server-side zone-change deletions can arrive with a
                // recordType the local schema doesn't map yet (e.g. a record
                // written by a newer app version). The precise invalidation
                // above silently no-ops there, which would strand stale rows
                // until the next full sync — so fall back to the same
                // all-types sweep the confirmed-delete path uses. Deletes are
                // low-frequency user actions, so sweeping the cache tables
                // imposes negligible overhead while guaranteeing no stale row
                // survives an unmapped-type deletion.
                guard CachedRecordType.recordType(for: deletion.recordType) == nil else { continue }
                let identity = ScopedRecordIdentity(
                    databaseScope: dbScope,
                    zoneID: deletion.recordID.zoneID,
                    recordID: deletion.recordID,
                    familyRecordName: activeFamily
                )
                for type in CachedRecordType.allCases {
                    await backgroundCache?.deleteRecord(identity: identity, type: type)
                    cacheService?.invalidate(identity: identity, type: type)
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
            // Refresh ONLY the server-stamped system fields on rows we already
            // own locally; full-record merges stay on the fetch path so local
            // optimistic edits made during the save round-trip are preserved.
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
            // Completion accounting must reflect actual cache writes only: a
            // pass that saved nothing (or whose rows all vanished mid-flight)
            // has no local state change to acknowledge. A failed context save,
            // however, is a real write failure and must surface as one —
            // collapsing it into the no-op case would silently strand the
            // refreshed rows with stale system fields.
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

        // Handle successful deletes — remove local cache rows on both background and main contexts.
        // CloudKit's sentRecordZoneChanges supplies confirmed deletedRecordIDs without recordType,
        // so we sweep CachedRecordType.allCases with the family- and zone-scoped identity.
        // Because deletes are low-frequency user actions, sweeping the 10 cache tables imposes
        // negligible overhead without cross-context contention while ensuring consistency across both contexts.
        if let activeFamily = appState?.family?.id.recordName {
            let scope = syncEngine.database.databaseScope
            for deletedRecordID in sentEvent.deletedRecordIDs {
                logger.info("Sent delete confirmed: \(deletedRecordID.recordName, privacy: .private)")
                let identity = ScopedRecordIdentity(
                    databaseScope: scope,
                    zoneID: deletedRecordID.zoneID,
                    recordID: deletedRecordID,
                    familyRecordName: activeFamily
                )
                for type in CachedRecordType.allCases {
                    await backgroundCache?.deleteRecord(identity: identity, type: type)
                    cacheService?.invalidate(identity: identity, type: type)
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
