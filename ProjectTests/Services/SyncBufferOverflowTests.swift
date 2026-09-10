//
//  SyncBufferOverflowTests.swift
//  LootList
//
//  Created by Ben Mackin on 9/9/26.
//

import CloudKit
import Foundation
@testable import LootList
import XCTest

@MainActor
final class SyncBufferOverflowTests: XCTestCase {
    var appState: AppState!
    var cloudKit: MockCloudKitService!
    var cacheService: CacheService!
    var conflictResolver: CKSyncConflictResolver!
    var backgroundCache: BackgroundCacheActor!
    var delegateHandler: CKSyncEngineDelegateHandler!
    var coordinator: CKSyncEngineCoordinator!
    var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        let suite = "test-suite-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        appState = AppState(defaults: defaults)
        cloudKit = MockCloudKitService()

        cacheService = try CacheService(inMemory: true)
        cacheService.invalidateAllFreshness()
        appState.cacheService = cacheService

        appState.family = Family(
            name: "Family",
            creatorUserRecordName: "user",
            id: CKRecord.ID(recordName: "active-family")
        )

        conflictResolver = CKSyncConflictResolver(
            cacheService: cacheService,
            appState: appState
        )

        let container = try XCTUnwrap(cacheService.container)
        backgroundCache = BackgroundCacheActor(container: container)

        delegateHandler = CKSyncEngineDelegateHandler(
            backgroundCache: backgroundCache,
            conflictResolver: conflictResolver,
            cacheService: cacheService,
            appState: appState
        )

        coordinator = CKSyncEngineCoordinator(
            cloudKitService: cloudKit,
            delegateHandler: delegateHandler,
            appState: appState,
            defaults: defaults
        )
    }

    override func tearDown() async throws {
        cacheService?.invalidateAllFreshness()
        try await super.tearDown()
    }

    // MARK: - Pending Buffer Overflow

    func testPendingBufferOverflowSetsFlagCounterAndInvalidatesFreshness() {
        cacheService.invalidateAllFreshness()
        cacheService.markCacheFreshForTests(familyRecordName: "active-family", type: .quest)
        XCTAssertTrue(cacheService.isCacheAuthoritative(familyRecordName: "active-family", type: .quest, scope: .private))

        enqueueUniqueSaves(count: 2001)

        XCTAssertTrue(coordinator.pendingBufferOverflowed)
        XCTAssertEqual(coordinator.pendingBufferDroppedCount, 1)
        // WHY: dropped queued writes may never reach the server, so freshness must clear and force re-hydration.
        XCTAssertFalse(
            cacheService.isCacheAuthoritative(familyRecordName: "active-family", type: .quest, scope: .private),
            "Dropping buffered writes must invalidate freshness for the active family"
        )
    }

    func testAcknowledgeBufferOverflowRecoveryRequiresDroppedIdentityResolution() {
        enqueueUniqueSaves(count: 2001)
        XCTAssertTrue(coordinator.pendingBufferOverflowed)
        XCTAssertEqual(coordinator.pendingBufferDroppedCount, 1)

        // The oldest buffered identity is evicted first.
        let droppedID = CKRecord.ID(recordName: "buffer-0")
        coordinator.acknowledgeBufferOverflowRecovery(
            reenqueuedSaveRecordIDs: [],
            reenqueuedDeleteRecordIDs: [],
            confirmedDeletedSaveRecordIDs: []
        )
        XCTAssertTrue(
            coordinator.pendingBufferOverflowed,
            "A dropped identity that was neither re-enqueued nor confirmed deleted must keep the loss visible"
        )
        XCTAssertEqual(coordinator.pendingBufferDroppedCount, 1)

        coordinator.acknowledgeBufferOverflowRecovery(
            reenqueuedSaveRecordIDs: [droppedID],
            reenqueuedDeleteRecordIDs: [],
            confirmedDeletedSaveRecordIDs: []
        )
        XCTAssertFalse(coordinator.pendingBufferOverflowed)
        XCTAssertEqual(coordinator.pendingBufferDroppedCount, 0)
    }

    func testAcknowledgeBufferOverflowRecoveryClearsOnlyWhenDroppedSaveConfirmedDeleted() {
        enqueueUniqueSaves(count: 2001)
        XCTAssertTrue(coordinator.pendingBufferOverflowed)

        let droppedID = CKRecord.ID(recordName: "buffer-0")
        coordinator.acknowledgeBufferOverflowRecovery(
            reenqueuedSaveRecordIDs: [],
            reenqueuedDeleteRecordIDs: [],
            confirmedDeletedSaveRecordIDs: [droppedID]
        )

        XCTAssertFalse(coordinator.pendingBufferOverflowed)
        XCTAssertEqual(coordinator.pendingBufferDroppedCount, 0)
    }

    func testDroppedUpdateSaveWithExistingChangeTagStaysTrackedUntilReenqueued() async throws {
        // An already-synced row keeps a non-nil changeTag, so the never-synced scan cannot see it and a
        // dropped edit would silently look resolved unless the overflow scan probes the tracked identity.
        let syncedName = "synced-quest"
        let context = try XCTUnwrap(cacheService.context)
        context.insert(QuestCache(
            recordName: syncedName,
            familyRecordName: "active-family",
            assigneeRecordName: "hero",
            templateRecordName: "tpl",
            weekOf: Date(),
            questName: "Synced Quest",
            isActive: true,
            goldReward: 5,
            xpReward: 50,
            rarity: "common",
            scheduleType: "weeklyFlexible",
            isAllOrNothing: false,
            approvalMode: "autoApprove",
            descriptionText: nil,
            createdByRecordName: "user",
            changeTag: "server-tag-1"
        ))
        try context.save()

        let syncedID = CKRecord.ID(recordName: syncedName)
        // Make the synced row's save the oldest candidate so filling the buffer evicts it.
        coordinator.enqueueSave(recordID: syncedID, isOwner: true)
        enqueueUniqueSaves(count: 2000)
        XCTAssertTrue(coordinator.pendingBufferOverflowed)
        XCTAssertEqual(coordinator.pendingBufferDroppedCount, 1)
        XCTAssertTrue(coordinator.unresolvedBufferOverflowIdentities.contains { $0.recordName == syncedName })

        let scanner = try BackgroundCacheActor(container: XCTUnwrap(cacheService.container))
        let scan = await scanner.fetchPendingRecordIDs(
            familyRecordName: "active-family",
            zoneID: syncedID.zoneID,
            trackedDroppedIdentities: coordinator.unresolvedBufferOverflowIdentities
        )
        XCTAssertTrue(
            scan.recordIDsToEnqueue.contains(syncedID),
            "An evicted update save must be re-discovered despite its non-nil changeTag"
        )
        XCTAssertFalse(scan.confirmedDeletedRecordIDs.contains(syncedID))

        // No engine carried the write yet, so the loss must stay visible.
        coordinator.acknowledgeBufferOverflowRecovery(
            reenqueuedSaveRecordIDs: [],
            reenqueuedDeleteRecordIDs: [],
            confirmedDeletedSaveRecordIDs: scan.confirmedDeletedRecordIDs
        )
        XCTAssertTrue(
            coordinator.pendingBufferOverflowed,
            "A dropped update save whose row still exists must stay unresolved until re-enqueued"
        )
        XCTAssertEqual(coordinator.pendingBufferDroppedCount, 1)

        // Handing the write to an active engine is the positive recovery signal.
        coordinator.acknowledgeBufferOverflowRecovery(
            reenqueuedSaveRecordIDs: [syncedID],
            reenqueuedDeleteRecordIDs: [],
            confirmedDeletedSaveRecordIDs: []
        )
        XCTAssertFalse(coordinator.pendingBufferOverflowed)
        XCTAssertEqual(coordinator.pendingBufferDroppedCount, 0)
    }

    func testFetchPassSettlementDoesNotClearPendingBufferOverflow() {
        enqueueUniqueSaves(count: 2001)
        XCTAssertTrue(coordinator.pendingBufferOverflowed)

        // A delta fetch re-hydrates but never re-enqueues evicted writes, so the visible loss must survive.
        coordinator.simulateFetchPassSettlement(activeScopes: [.private], completedScopes: [.private])

        XCTAssertTrue(coordinator.pendingBufferOverflowed)
        XCTAssertEqual(coordinator.pendingBufferDroppedCount, 1)
    }

    func testResetStateClearsPendingBufferOverflow() {
        enqueueUniqueSaves(count: 2001)
        XCTAssertTrue(coordinator.pendingBufferOverflowed)

        coordinator.resetState()

        XCTAssertFalse(coordinator.pendingBufferOverflowed)
        XCTAssertEqual(coordinator.pendingBufferDroppedCount, 0)
    }

    // MARK: - Dropped Delete Recovery

    func testDroppedDeleteWithAbsentCacheRowStaysTrackedUntilDeleteReenqueued() async {
        // A delete's cache row is invalidated before enqueueDelete, so by overflow time the row is already
        // gone. Cache-row absence must therefore never read as delete recovery.
        enqueueUniqueDeletes(count: 2001)
        XCTAssertTrue(coordinator.pendingBufferOverflowed)
        XCTAssertEqual(coordinator.pendingBufferDroppedCount, 1)

        let droppedID = CKRecord.ID(recordName: "delete-buffer-0")
        XCTAssertTrue(
            coordinator.unresolvedBufferOverflowIdentities.contains {
                $0.recordName == droppedID.recordName && $0.operation == .delete
            },
            "A dropped delete must be recorded as a delete, not conflated with a dropped save"
        )

        let scan = await backgroundCache.fetchPendingRecordIDs(
            familyRecordName: "active-family",
            zoneID: droppedID.zoneID,
            trackedDroppedIdentities: coordinator.unresolvedBufferOverflowIdentities
        )
        XCTAssertFalse(scan.confirmedDeletedRecordIDs.contains(droppedID))
        XCTAssertTrue(scan.deleteRecordIDsToEnqueue.contains(droppedID))
        XCTAssertFalse(scan.recordIDsToEnqueue.contains(droppedID))

        // Even an (incorrectly) reported confirmed deletion must not clear a dropped delete.
        coordinator.acknowledgeBufferOverflowRecovery(
            reenqueuedSaveRecordIDs: [],
            reenqueuedDeleteRecordIDs: [],
            confirmedDeletedSaveRecordIDs: [droppedID]
        )
        XCTAssertTrue(
            coordinator.pendingBufferOverflowed,
            "A dropped delete must stay visible until it is handed to an engine as a delete"
        )

        coordinator.acknowledgeBufferOverflowRecovery(
            reenqueuedSaveRecordIDs: [],
            reenqueuedDeleteRecordIDs: [droppedID],
            confirmedDeletedSaveRecordIDs: []
        )
        XCTAssertFalse(coordinator.pendingBufferOverflowed)
        XCTAssertEqual(coordinator.pendingBufferDroppedCount, 0)
    }

    // MARK: - Dropped Delete Superseded By Later Write

    func testDroppedDeleteThenReSavedBeforeRecoveryNeverReenqueuesDelete() async throws {
        // A deterministic record identity lets a record be deleted and then re-created before recovery. The
        // evicted delete must be superseded by the newer save, or recovery would re-issue a DELETE and
        // silently destroy the re-created server record.
        enqueueUniqueDeletes(count: 2001)
        let droppedID = CKRecord.ID(recordName: "delete-buffer-0")
        XCTAssertTrue(
            coordinator.unresolvedBufferOverflowIdentities.contains {
                $0.recordName == droppedID.recordName && $0.operation == .delete
            },
            "The overflowed delete must start out tracked as a delete"
        )

        try insertNeverSyncedQuest(named: droppedID.recordName)
        coordinator.enqueueSave(recordID: droppedID, isOwner: true)

        // The newer save supersedes the evicted delete, so the loss signal must clear.
        XCTAssertFalse(
            coordinator.pendingBufferOverflowed,
            "A newer save must clear the dropped-delete loss signal"
        )
        XCTAssertEqual(coordinator.pendingBufferDroppedCount, 0)
        XCTAssertFalse(
            coordinator.unresolvedBufferOverflowIdentities.contains { $0.recordName == droppedID.recordName },
            "A superseded delete must stop being tracked for recovery"
        )

        // Recovery must never re-issue a delete for the re-created identity.
        let scan = await backgroundCache.fetchPendingRecordIDs(
            familyRecordName: "active-family",
            zoneID: droppedID.zoneID,
            trackedDroppedIdentities: coordinator.unresolvedBufferOverflowIdentities
        )
        XCTAssertFalse(
            scan.deleteRecordIDsToEnqueue.contains(droppedID),
            "A superseded delete must never be re-enqueued as a delete"
        )
        XCTAssertTrue(
            scan.recordIDsToEnqueue.contains(droppedID),
            "The re-created record must still be uploaded as a save"
        )
    }

    func testTrackedDeleteSupersededByPendingNeverSyncedSave() async throws {
        // Defense-in-depth: if the loss ledger still holds the delete, a pending never-synced save for the
        // same identity is a newer local write and the scan must supersede the delete rather than re-issue it.
        enqueueUniqueDeletes(count: 2001)
        let droppedID = CKRecord.ID(recordName: "delete-buffer-0")
        try insertNeverSyncedQuest(named: droppedID.recordName)

        let scan = await backgroundCache.fetchPendingRecordIDs(
            familyRecordName: "active-family",
            zoneID: droppedID.zoneID,
            trackedDroppedIdentities: coordinator.unresolvedBufferOverflowIdentities
        )
        XCTAssertTrue(
            scan.supersededDeleteRecordIDs.contains(droppedID),
            "A tracked delete with a pending never-synced save must be reported as superseded"
        )
        XCTAssertFalse(scan.deleteRecordIDsToEnqueue.contains(droppedID))
        XCTAssertTrue(scan.recordIDsToEnqueue.contains(droppedID))

        coordinator.acknowledgeBufferOverflowRecovery(
            reenqueuedSaveRecordIDs: [],
            reenqueuedDeleteRecordIDs: [],
            confirmedDeletedSaveRecordIDs: [],
            supersededDeleteRecordIDs: scan.supersededDeleteRecordIDs
        )
        XCTAssertFalse(coordinator.pendingBufferOverflowed)
        XCTAssertEqual(coordinator.pendingBufferDroppedCount, 0)
    }

    // MARK: - Dropped Count Display Truth

    func testDroppedCountTracksExactRemainingLossOnPartialRecovery() {
        enqueueUniqueSaves(count: 2002)
        XCTAssertTrue(coordinator.pendingBufferOverflowed)
        XCTAssertEqual(coordinator.pendingBufferDroppedCount, 2)

        coordinator.acknowledgeBufferOverflowRecovery(
            reenqueuedSaveRecordIDs: [CKRecord.ID(recordName: "buffer-0")],
            reenqueuedDeleteRecordIDs: [],
            confirmedDeletedSaveRecordIDs: []
        )
        XCTAssertTrue(coordinator.pendingBufferOverflowed)
        XCTAssertEqual(
            coordinator.pendingBufferDroppedCount,
            1,
            "Partial recovery must leave the exact remaining loss, never a stale inflated count"
        )

        coordinator.acknowledgeBufferOverflowRecovery(
            reenqueuedSaveRecordIDs: [CKRecord.ID(recordName: "buffer-1")],
            reenqueuedDeleteRecordIDs: [],
            confirmedDeletedSaveRecordIDs: []
        )
        XCTAssertFalse(coordinator.pendingBufferOverflowed)
        XCTAssertEqual(coordinator.pendingBufferDroppedCount, 0)
    }

    // MARK: - Durable Overflow Ledger

    func testBufferOverflowLedgerRehydratesAfterRelaunchAndReprobesSyncedRows() async throws {
        // An already-synced row keeps a non-nil changeTag, so the launch scan cannot see it unless the
        // persisted overflow ledger rehydrates the tracked identity.
        let syncedName = "buffer-synced"
        let context = try XCTUnwrap(cacheService.context)
        context.insert(QuestCache(
            recordName: syncedName,
            familyRecordName: "active-family",
            assigneeRecordName: "hero",
            templateRecordName: "tpl",
            weekOf: Date(),
            questName: "Synced Quest",
            isActive: true,
            goldReward: 5,
            xpReward: 50,
            rarity: "common",
            scheduleType: "weeklyFlexible",
            isAllOrNothing: false,
            approvalMode: "autoApprove",
            descriptionText: nil,
            createdByRecordName: "user",
            changeTag: "server-tag-1"
        ))
        try context.save()

        let syncedID = CKRecord.ID(recordName: syncedName)
        coordinator.enqueueSave(recordID: syncedID, isOwner: true)
        enqueueUniqueSaves(count: 2000)
        XCTAssertTrue(coordinator.pendingBufferOverflowed)
        XCTAssertEqual(coordinator.pendingBufferDroppedCount, 1)
        XCTAssertTrue(coordinator.unresolvedBufferOverflowIdentities.contains { $0.recordName == syncedName })

        // Rebuild the coordinator over the same defaults to simulate a jetsam relaunch.
        let relaunchedHandler = CKSyncEngineDelegateHandler(
            backgroundCache: backgroundCache,
            conflictResolver: conflictResolver,
            cacheService: cacheService,
            appState: appState
        )
        let relaunched = CKSyncEngineCoordinator(
            cloudKitService: cloudKit,
            delegateHandler: relaunchedHandler,
            appState: appState,
            defaults: defaults
        )
        XCTAssertFalse(relaunched.pendingBufferOverflowed, "Fresh in-memory state starts with no tracked loss")

        relaunched.rehydrateBufferOverflowLedger()

        XCTAssertTrue(relaunched.pendingBufferOverflowed, "The loss signal must survive process termination")
        XCTAssertEqual(relaunched.pendingBufferDroppedCount, 1)
        XCTAssertTrue(relaunched.unresolvedBufferOverflowIdentities.contains { $0.recordName == syncedName })

        let scanner = try BackgroundCacheActor(container: XCTUnwrap(cacheService.container))
        let scan = await scanner.fetchPendingRecordIDs(
            familyRecordName: "active-family",
            zoneID: syncedID.zoneID,
            trackedDroppedIdentities: relaunched.unresolvedBufferOverflowIdentities
        )
        XCTAssertTrue(
            scan.recordIDsToEnqueue.contains(syncedID),
            "A rehydrated non-nil-changeTag identity must be re-probed and re-enqueued on launch"
        )
    }

    // MARK: - Change Age Marker

    func testEngineFetchedChangesStampChangeAgeIndependentOfPushAge() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "change-age-zone", ownerName: CKCurrentUserDefaultName)
        appState.family = Family(
            name: "Change Age",
            creatorUserRecordName: "user",
            id: CKRecord.ID(recordName: "active-family", zoneID: zoneID)
        )
        appState.familyZoneID = zoneID

        // WHY: push/reconcile age is a separate inbound event and must not masquerade as an engine change.
        coordinator.notePushReceived()
        XCTAssertNotNil(coordinator.lastPushReceivedAt)
        XCTAssertNil(coordinator.lastChangeReceivedAt)

        let profile = try Profile(
            displayName: "Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "icloud-user-1", zoneID: zoneID),
            family: CKRecord.Reference(recordID: XCTUnwrap(appState.family?.id), action: .none),
            id: CKRecord.ID(recordName: "change-profile", zoneID: zoneID)
        )

        await delegateHandler.simulateFetchedRecordZoneChanges(
            modifications: [profile.toRecord()],
            databaseScope: .private
        )

        XCTAssertNotNil(coordinator.lastChangeReceivedAt, "Engine-delivered records must stamp the change marker")
    }

    func testResetStateClearsLastChangeReceivedAt() {
        coordinator.noteChangeReceived()
        XCTAssertNotNil(coordinator.lastChangeReceivedAt)

        coordinator.resetState()

        XCTAssertNil(coordinator.lastChangeReceivedAt)
    }

    // MARK: - Helpers

    /// Enqueues distinct identities while no engine is active so each lands in the bounded pending buffer.
    private func enqueueUniqueSaves(count: Int) {
        for index in 0 ..< count {
            coordinator.enqueueSave(
                recordID: CKRecord.ID(recordName: "buffer-\(index)"),
                isOwner: true
            )
        }
    }

    /// Enqueues distinct deletes while no engine is active so each lands in the bounded pending buffer.
    private func enqueueUniqueDeletes(count: Int) {
        for index in 0 ..< count {
            coordinator.enqueueDelete(
                recordID: CKRecord.ID(recordName: "delete-buffer-\(index)"),
                isOwner: true
            )
        }
    }

    /// Inserts a never-synced quest row (nil changeTag) so the pending scan discovers it as a fresh save.
    private func insertNeverSyncedQuest(named recordName: String) throws {
        let context = try XCTUnwrap(cacheService.context)
        context.insert(QuestCache(
            recordName: recordName,
            familyRecordName: "active-family",
            assigneeRecordName: "hero",
            templateRecordName: "tpl",
            weekOf: Date(),
            questName: "Re-created Quest",
            isActive: true,
            goldReward: 5,
            xpReward: 50,
            rarity: "common",
            scheduleType: "weeklyFlexible",
            isAllOrNothing: false,
            approvalMode: "autoApprove",
            descriptionText: nil,
            createdByRecordName: "user",
            changeTag: nil
        ))
        try context.save()
    }
}
