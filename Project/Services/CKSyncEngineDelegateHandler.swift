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

    /// Inbound sync is off-main: parses on MainActor then hands Sendable
    /// ParsedRecords to BackgroundCacheActor for batched, single-save
    /// persistence. The actor's DefaultSerialModelExecutor + autosaveEnabled=false
    /// ensures the save triggers ModelContext.didSave → CacheService
    /// processPendingChanges exactly once per batch for atomic @Query visibility.
    /// Dual-scope is derived via databaseScope ?? (isZoneOwner ? .private : .shared)
    /// and validated via identity.matchesActiveScope; shared and private engines
    /// share this identical pipeline.
    func handleIncomingRecordsDirectly(
        _ records: [CKRecord],
        databaseScope: CKDatabase.Scope? = nil,
        zoneID: CKRecordZone.ID? = nil
    ) async {
        var validRecords: [ParsedRecord] = []
        var parseFailureCount = 0
        let activeZone = appState?.familyZoneID
        let activeFamily = appState?.family?.id.recordName
        let scope: CKDatabase.Scope = databaseScope ?? ((appState?.isZoneOwner == true) ? .private : .shared)
        let expectedDbScope: CKDatabase.Scope? = (appState?.isZoneOwner == true) ? .private : .shared

        for record in records {
            let recordZone = zoneID ?? record.recordID.zoneID
            let identity = ScopedRecordIdentity(
                databaseScope: scope,
                zoneID: recordZone,
                recordID: record.recordID,
                familyRecordName: activeFamily
            )

            // Validate scope using identity.matchesActiveScope
            if let activeZone, let activeFamily {
                guard identity.matchesActiveScope(
                    expectedFamily: activeFamily,
                    expectedZone: activeZone,
                    expectedDatabase: expectedDbScope
                ) else {
                    logger.debug("Skipping incoming record outside active scope: \(record.recordID.recordName)")
                    continue
                }
            } else if let activeZone, recordZone != activeZone {
                logger.debug("Skipping incoming record from foreign zone: \(recordZone.zoneName)")
                continue
            }

            let parsed = ParsedRecord.parse(record: record)
            switch parsed {
            case .parseFailure:
                parseFailureCount += 1
                coordinator?.noteParseFailure()
                logger.error("Parse failure for incoming record: type=\(record.recordType, privacy: .public), id=\(record.recordID.recordName, privacy: .private)")
            case .ignoredSystemRecord:
                logger.debug("Ignored system record: type=\(record.recordType, privacy: .public), id=\(record.recordID.recordName, privacy: .private)")
            default:
                validRecords.append(parsed)
            }
        }

        if parseFailureCount > 0 {
            logger.warning("\(parseFailureCount) record(s) failed to parse during incoming zone changes")
        }

        if !validRecords.isEmpty {
            // Concurrent batch commits (e.g. private + shared engines racing)
            // are linearized by SerialMutationQueue.shared inside
            // batchUpsertParsedRecords, and each commit lands the entire
            // ParsedBatch in one ModelContext.save for atomic visibility — no
            // intermediate saves between families/profiles and secondary
            // entities (LedgerEntry/AllowancePeriod/RewardEvent hydration).
            let writeSuccess = await backgroundCache?.batchUpsertParsedRecords(validRecords) ?? false
            if writeSuccess {
                coordinator?.noteChangesProcessed()
                await triggerSyncNotifications(for: validRecords)
            } else {
                coordinator?.noteCacheWriteFailure()
                logger.error("Cache write failure during incoming zone changes")
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

        if let activeFamily = appState?.family?.id.recordName {
            let dbScope = databaseScope ?? ((appState?.isZoneOwner == true) ? .private : .shared)
            for deletion in changes.deletions {
                await conflictResolver.handleDeletedRecord(
                    recordID: deletion.recordID,
                    recordType: deletion.recordType,
                    databaseScope: dbScope,
                    familyRecordName: activeFamily
                )
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
        var validRecords: [ParsedRecord] = []
        var parseFailureCount = 0
        for savedRecord in sentEvent.savedRecords {
            let parsed = ParsedRecord.parse(record: savedRecord)
            switch parsed {
            case .parseFailure:
                parseFailureCount += 1
                coordinator?.noteParseFailure()
                logger.error("Parse failure for sent saved record: type=\(savedRecord.recordType, privacy: .public), id=\(savedRecord.recordID.recordName, privacy: .private)")
            case .ignoredSystemRecord:
                logger.debug("Ignored sent system record: type=\(savedRecord.recordType, privacy: .public), id=\(savedRecord.recordID.recordName, privacy: .private)")
            default:
                validRecords.append(parsed)
            }
        }

        if parseFailureCount > 0 {
            logger.warning("\(parseFailureCount) record(s) failed to parse during sent zone changes")
        }

        if !validRecords.isEmpty {
            let writeSuccess = await backgroundCache?.batchUpsertParsedRecords(validRecords) ?? false
            if writeSuccess {
                coordinator?.noteChangesProcessed()
            } else {
                coordinator?.noteCacheWriteFailure()
                logger.error("Cache write failure during sent zone changes")
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
