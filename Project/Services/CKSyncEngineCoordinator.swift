//
//  CKSyncEngineCoordinator.swift
//  LootList
//
//  Created by Ben Mackin on 8/13/26.
//

import CloudKit
import Foundation
import Observation
import os
import Synchronization

/// WHY op kind: a dropped delete must re-enqueue as a delete — a locally absent cache row is the delete's
/// normal state and never proves the tombstone reached CloudKit.
enum PendingBufferOperation: String, Sendable {
    case save
    case delete
}

/// WHY value type: the overflow scan runs off-main on `BackgroundCacheActor`, so tracked loss crosses
/// actors as a `Sendable` snapshot of record name + operation.
struct BufferOverflowIdentity: Sendable, Hashable {
    let recordName: String
    let operation: PendingBufferOperation
}

/// WHY single engine: private and shared scopes share one lifecycle.
@MainActor
@Observable
final class CKSyncEngineCoordinator: SyncEnqueuing {
    private let logger = Logger(category: "CKSyncEngineCoordinator")

    // MARK: - State Key Resolution

    /// Resolves stable family identifier scoping engine state.
    private func stableFamilyRecordName() -> String? {
        // WHY family-first: zone names can collide across families.
        if let familyRecordName = appState?.family?.id.recordName, !familyRecordName.isEmpty {
            return familyRecordName
        }
        if let zoneName = cloudKitService.activeFamilyZoneID?.zoneName, !zoneName.isEmpty {
            return zoneName
        }
        return nil
    }

    /// Builds UserDefaults state key per family and database scope.
    private func stateKey(for scope: CKDatabase.Scope) -> String? {
        guard let familyRecordName = stableFamilyRecordName() else {
            return nil
        }
        return (scope == .private)
            ? "ck_sync_engine_state.\(familyRecordName).private"
            : "ck_sync_engine_state.\(familyRecordName).shared"
    }

    let cloudKitService: any CloudKitServiceProtocol
    let delegateHandler: CKSyncEngineDelegateHandler
    let defaults: UserDefaults

    /// Weak session reference used to resolve active family for freshness stamping.
    private weak var appState: AppState?

    @ObservationIgnored var privateSyncEngine: CKSyncEngine?
    @ObservationIgnored var sharedSyncEngine: CKSyncEngine?

    @ObservationIgnored private var passProducedChanges = false
    @ObservationIgnored private var activeFetchPassScopes: Set<CKDatabase.Scope> = []
    @ObservationIgnored private var completedFetchPassScopes: Set<CKDatabase.Scope> = []
    @ObservationIgnored private var currentPassHadParseFailures = false
    @ObservationIgnored private var currentPassHadCacheWriteFailures = false
    @ObservationIgnored private let pendingEnqueueBuffer = Mutex<[ScopedRecordIdentity]>([])
    @ObservationIgnored private let pendingDeleteBuffer = Mutex<[ScopedRecordIdentity]>([])
    // WHY backoff retry: unverified deletions re-evaluate without tight spin.
    // WHY nonisolated retry: deinit cancels without hopping to MainActor.
    @ObservationIgnored private nonisolated let retryDeadlines = Mutex<[String: Date]>([:])
    @ObservationIgnored private nonisolated let retryAttempts = Mutex<[String: Int]>([:])
    // WHY coalesced retry: per-record tasks cancel on overwrite and teardown.
    @ObservationIgnored private nonisolated let retryTasks = Mutex<[String: Task<Void, Never>]>([:])

    var isSyncing: Bool = false
    var lastSyncedAt: Date?
    var syncError: String?
    private(set) var lastPushReceivedAt: Date?
    /// WHY display-truth: engine-delivered changes land outside coordinator passes, so change age tracks the engine while push/reconcile age tracks every inbound event. Never
    /// stamps freshness.
    private(set) var lastChangeReceivedAt: Date?
    // WHY visible loss: capped buffers drop oldest, so the flag forces re-hydration instead of trusting diverged cache.
    private(set) var pendingBufferOverflowed = false
    private(set) var pendingBufferDroppedCount = 0
    /// WHY deferred recovery: evicted identities stay tracked until the overflow scan hands them to an
    /// active engine or proves their cache row is gone, so a fetch/send pass alone cannot clear the loss.
    /// WHY op kind: keying by record ID records save-vs-delete at eviction time, so a dropped delete is
    /// never cleared by a vanished cache row and re-enqueues as a delete.
    @ObservationIgnored private var droppedBufferEntries: [CKRecord.ID: PendingBufferOperation] = [:]

    @ObservationIgnored private var lastSendCompletedAt: Date?
    private static let sendCoalescingInterval: TimeInterval = 2
    /// WHY bounded buffers: offline days with large ledgers must not grow pending queues without limit.
    private static let maxBufferedIdentities = 2000

    var pendingUploadCount: Int {
        var count = 0
        if let privateSyncEngine {
            count += privateSyncEngine.state.pendingRecordZoneChanges.count
        }
        if let sharedSyncEngine {
            count += sharedSyncEngine.state.pendingRecordZoneChanges.count
        }
        return count
    }

    init(
        cloudKitService: any CloudKitServiceProtocol,
        delegateHandler: CKSyncEngineDelegateHandler,
        appState: AppState? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.cloudKitService = cloudKitService
        self.delegateHandler = delegateHandler
        self.appState = appState
        self.defaults = defaults

        delegateHandler.setCoordinator(self)
    }

    deinit {
        // Cancel any pending retry Tasks to avoid re-enqueue after coordinator teardown.
        let tasks = retryTasks.withLock { Array($0.values) }
        for task in tasks {
            task.cancel()
        }
    }

    // MARK: - Engine Setup

    func initializeEngines() {
        // WHY before the test guard: the persisted loss ledger must reload on every launch, including
        // environments that never instantiate a real engine.
        rehydrateBufferOverflowLedger()
        // Skips engine initialization in unit test environments.
        guard !TestEnvironment.isRunningUnitOrUITests else {
            logger.info("CKSyncEngine initialization skipped: unit test environment")
            return
        }
        guard let appState,
              appState.authStatus == .authenticated,
              let family = appState.family,
              let profile = appState.currentProfile,
              let zoneID = appState.familyZoneID,
              family.id.zoneID == zoneID,
              profile.id.zoneID == zoneID,
              profile.family.recordID == family.id
        else {
            logger.info("CKSyncEngine initialization skipped: no authenticated family scope")
            return
        }

        cloudKitService.activeFamilyZoneID = zoneID
        cloudKitService.activeIsOwner = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState)
        setupEngines()
    }

    private func setupEngines() {
        guard !TestEnvironment.isRunningUnitOrUITests else {
            logger.info("CKSyncEngine setup skipped: unit test environment")
            return
        }
        guard let ckConcrete = cloudKitService as? CloudKitService else { return }

        // Fail-closed: an unresolved session mints no engine — pending mutations
        // stay buffered until an authenticated scope resolves, matching the
        // activeEngine accessor contract.
        guard let appState else {
            logger.warning("CKSyncEngine setup skipped: unresolved session — pending changes stay buffered")
            return
        }

        let isOwner = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState)
        let storedOwner = appState.isZoneOwner
        if isOwner != storedOwner {
            logger.warning("CKSyncEngineCoordinator.setupEngines isOwner corrected via creator anchor: stored=\(storedOwner) resolved=\(isOwner)")
        }
        if isOwner {
            sharedSyncEngine = nil
            if privateSyncEngine == nil {
                privateSyncEngine = makeEngine(for: .private, container: ckConcrete.container)
            }
        } else {
            privateSyncEngine = nil
            if sharedSyncEngine == nil {
                sharedSyncEngine = makeEngine(for: .shared, container: ckConcrete.container)
            }
        }
        drainPendingEnqueueBuffers()
    }

    /// Single construction path for live engines — both scopes differ only in
    /// database and persisted-state key, so the CKSyncEngine mint exists exactly once.
    private func makeEngine(for scope: CKDatabase.Scope, container: CKContainer) -> CKSyncEngine {
        let database = (scope == .private)
            ? container.privateCloudDatabase
            : container.sharedCloudDatabase
        let config = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: loadState(for: scope),
            delegate: delegateHandler
        )
        return CKSyncEngine(config)
    }

    private func drainPendingEnqueueBuffers() {
        let saves = pendingEnqueueBuffer.withLock { buffer -> [ScopedRecordIdentity] in
            let copy = buffer
            buffer.removeAll()
            return copy
        }
        for identity in saves {
            let isOwner = identity.databaseScope == .private
            if let engine = activeEngine(isOwner: isOwner) {
                engine.state.add(pendingRecordZoneChanges: [.saveRecord(identity.recordID)])
                logger.info("Drained buffered save: \(identity.recordID.recordName, privacy: .private)")
            } else {
                restoreSaveIdentity(identity)
            }
        }
        let deletes = pendingDeleteBuffer.withLock { buffer -> [ScopedRecordIdentity] in
            let copy = buffer
            buffer.removeAll()
            return copy
        }
        for identity in deletes {
            let isOwner = identity.databaseScope == .private
            if let engine = activeEngine(isOwner: isOwner) {
                engine.state.add(pendingRecordZoneChanges: [.deleteRecord(identity.recordID)])
                logger.info("Drained buffered delete: \(identity.recordID.recordName, privacy: .private)")
            } else {
                restoreDeleteIdentity(identity)
            }
        }
    }

    /// WHY shared eviction: save, delete, and drain-restore paths all cap identically, so the 2000 cap,
    /// eviction arithmetic, and fault logging live in one place rather than drifting per path.
    /// WHY nonisolated: the eviction runs inside the `Mutex` lock, so it must not require actor isolation.
    private nonisolated static func evictOverflow(
        from buffer: inout [ScopedRecordIdentity],
        cap: Int,
        operation: PendingBufferOperation,
        logger: Logger
    ) -> [ScopedRecordIdentity] {
        guard buffer.count > cap else { return [] }
        let overflow = buffer.count - cap
        let evicted = Array(buffer.prefix(overflow))
        buffer.removeFirst(overflow)
        let noun = operation == .save ? "saves" : "deletes"
        logger
            .fault(
                "Pending \(operation.rawValue, privacy: .public) buffer capped at \(cap, privacy: .public) — dropped \(overflow, privacy: .public) oldest \(noun, privacy: .public)"
            )
        return evicted
    }

    /// WHY dedupe+cap: offline bursts re-enqueue the same record repeatedly, so buffered saves stay unique and bounded.
    private func bufferSaveIdentity(_ identity: ScopedRecordIdentity) {
        let cap = Self.maxBufferedIdentities
        let log = logger
        pendingDeleteBuffer.withLock { $0.removeAll { $0.recordID == identity.recordID } }
        let dropped = pendingEnqueueBuffer.withLock { buffer -> [ScopedRecordIdentity] in
            buffer.removeAll { $0.recordID == identity.recordID }
            buffer.append(identity)
            return Self.evictOverflow(from: &buffer, cap: cap, operation: .save, logger: log)
        }
        noteBufferOverflow(identities: dropped, operation: .save)
    }

    /// WHY dedupe+cap: delete retries must not duplicate or grow without bound while offline.
    private func bufferDeleteIdentity(_ identity: ScopedRecordIdentity) {
        let cap = Self.maxBufferedIdentities
        let log = logger
        pendingEnqueueBuffer.withLock { $0.removeAll { $0.recordID == identity.recordID } }
        let dropped = pendingDeleteBuffer.withLock { buffer -> [ScopedRecordIdentity] in
            buffer.removeAll { $0.recordID == identity.recordID }
            buffer.append(identity)
            return Self.evictOverflow(from: &buffer, cap: cap, operation: .delete, logger: log)
        }
        noteBufferOverflow(identities: dropped, operation: .delete)
    }

    /// WHY no cross-clear: drain restore preserves intent, so saves and deletes re-queue independently.
    private func restoreSaveIdentity(_ identity: ScopedRecordIdentity) {
        let cap = Self.maxBufferedIdentities
        let log = logger
        let dropped = pendingEnqueueBuffer.withLock { buffer -> [ScopedRecordIdentity] in
            guard !buffer.contains(where: { $0.recordID == identity.recordID }) else { return [] }
            buffer.append(identity)
            return Self.evictOverflow(from: &buffer, cap: cap, operation: .save, logger: log)
        }
        noteBufferOverflow(identities: dropped, operation: .save)
    }

    /// WHY no cross-clear: drain restore preserves intent, so deletes survive alongside saves.
    private func restoreDeleteIdentity(_ identity: ScopedRecordIdentity) {
        let cap = Self.maxBufferedIdentities
        let log = logger
        let dropped = pendingDeleteBuffer.withLock { buffer -> [ScopedRecordIdentity] in
            guard !buffer.contains(where: { $0.recordID == identity.recordID }) else { return [] }
            buffer.append(identity)
            return Self.evictOverflow(from: &buffer, cap: cap, operation: .delete, logger: log)
        }
        noteBufferOverflow(identities: dropped, operation: .delete)
    }

    /// WHY cross-kind only: a newer write of the other kind can no longer be represented by the evicted
    /// operation, so it supersedes the recovery record. Same-kind re-buffers stay tracked until an engine
    /// accepts them (drain hand-off), which is what keeps dropped deletes from reading as locally resolved.
    private func supersedeDroppedBufferEntry(for recordID: CKRecord.ID, with operation: PendingBufferOperation) {
        guard let tracked = droppedBufferEntries[recordID], tracked != operation else { return }
        droppedBufferEntries.removeValue(forKey: recordID)
        persistBufferOverflowLedger()
        refreshBufferOverflowState()
    }

    /// WHY diverge-then-heal: dropped queued writes may never reach the server, so freshness clears and the
    /// next pass re-hydrates; evicted identities stay tracked with their operation so a dropped delete is
    /// never cleared by a vanished cache row.
    private func noteBufferOverflow(identities: [ScopedRecordIdentity], operation: PendingBufferOperation) {
        guard !identities.isEmpty else { return }
        for identity in identities {
            droppedBufferEntries[identity.recordID] = operation
        }
        persistBufferOverflowLedger()
        refreshBufferOverflowState()
        guard let cacheService = appState?.cacheService else { return }
        if let familyRecordName = appState?.family?.id.recordName, !familyRecordName.isEmpty {
            cacheService.invalidateFreshness(forFamilyRecordName: familyRecordName)
        } else {
            cacheService.invalidateAllFreshness()
        }
    }

    /// WHY full reset: account/family teardown drops the recovery ledger along with the visible loss signal.
    private func clearBufferOverflow() {
        droppedBufferEntries.removeAll()
        if let key = bufferOverflowLedgerKey() {
            defaults.removeObject(forKey: key)
        }
        refreshBufferOverflowState()
    }

    /// WHY derived display: the count mirrors the unresolved ledger exactly, so partial recovery never
    /// leaves a stale inflated total and re-dropping a tracked identity cannot double-count.
    private func refreshBufferOverflowState() {
        pendingBufferOverflowed = !droppedBufferEntries.isEmpty
        pendingBufferDroppedCount = droppedBufferEntries.count
    }

    /// Record names and pending operations whose buffered write was evicted on overflow and has not yet been
    /// positively recovered. WHY exposed: the overflow scan must probe these so an already-synced row
    /// (non-nil changeTag) keeps its loss signal until the write is re-enqueued.
    var unresolvedBufferOverflowIdentities: [BufferOverflowIdentity] {
        droppedBufferEntries.map { BufferOverflowIdentity(recordName: $0.key.recordName, operation: $0.value) }
    }

    /// WHY positive proof: a fetch or send pass re-hydrates but never re-enqueues evicted writes, so the
    /// visible loss clears only when the overflow scan hands each dropped identity to an active engine or
    /// no longer has a cache row; a dropped delete resolves only after being handed back as a delete, since
    /// a locally absent row is the delete's normal state and proves nothing. A delete superseded by a newer
    /// save resolves too: the newer write is authoritative, so re-issuing the delete would destroy it.
    func acknowledgeBufferOverflowRecovery(
        reenqueuedSaveRecordIDs: [CKRecord.ID],
        reenqueuedDeleteRecordIDs: [CKRecord.ID],
        confirmedDeletedSaveRecordIDs: Set<CKRecord.ID>,
        supersededDeleteRecordIDs: Set<CKRecord.ID> = []
    ) {
        guard !droppedBufferEntries.isEmpty else { return }
        let reenqueuedSaves = Set(reenqueuedSaveRecordIDs)
        let reenqueuedDeletes = Set(reenqueuedDeleteRecordIDs)
        var survivors: [CKRecord.ID: PendingBufferOperation] = [:]
        for (recordID, operation) in droppedBufferEntries {
            switch operation {
            case .save:
                if reenqueuedSaves.contains(recordID) || confirmedDeletedSaveRecordIDs.contains(recordID) {
                    continue
                }
            case .delete:
                if reenqueuedDeletes.contains(recordID) || supersededDeleteRecordIDs.contains(recordID) {
                    continue
                }
            }
            survivors[recordID] = operation
        }
        droppedBufferEntries = survivors
        persistBufferOverflowLedger()
        refreshBufferOverflowState()
    }

    // MARK: - Overflow Ledger Persistence

    /// WHY device-local: the ledger is scoped per family and holds no authoritative domain data, only
    /// display-truth loss tracking that must survive jetsam.
    private func bufferOverflowLedgerKey() -> String? {
        guard let familyRecordName = stableFamilyRecordName(), !familyRecordName.isEmpty else { return nil }
        return "ck_buffer_overflow.\(familyRecordName)"
    }

    private func persistBufferOverflowLedger() {
        guard let key = bufferOverflowLedgerKey() else { return }
        guard !droppedBufferEntries.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        let encoded = Dictionary(
            droppedBufferEntries.map { ($0.key.recordName, $0.value.rawValue) },
            uniquingKeysWith: { _, latest in latest }
        )
        defaults.set(encoded, forKey: key)
    }

    /// WHY relaunch recovery: an evicted update to an already-synced row is invisible to the never-synced
    /// scan, so the ledger reloads before the first reconciliation pass and re-probes its identities.
    func rehydrateBufferOverflowLedger() {
        guard droppedBufferEntries.isEmpty,
              let key = bufferOverflowLedgerKey(),
              let stored = defaults.dictionary(forKey: key) as? [String: String]
        else { return }
        let zoneID = appState?.familyZoneID ?? appState?.family?.id.zoneID ?? CKRecordZone.default().zoneID
        var restored: [CKRecord.ID: PendingBufferOperation] = [:]
        for (recordName, rawValue) in stored {
            guard let operation = PendingBufferOperation(rawValue: rawValue) else { continue }
            restored[CKRecord.ID(recordName: recordName, zoneID: zoneID)] = operation
        }
        droppedBufferEntries = restored
        refreshBufferOverflowState()
        guard let cacheService = appState?.cacheService else { return }
        if let familyRecordName = appState?.family?.id.recordName, !familyRecordName.isEmpty {
            cacheService.invalidateFreshness(forFamilyRecordName: familyRecordName)
        } else {
            cacheService.invalidateAllFreshness()
        }
    }

    // MARK: - Active Engine Selection

    /// Fail-closed accessor: engines exist only after `initializeEngines` passes the authenticated-scope
    /// gate, so a mutation arriving during a signed-out or account-transition window buffers instead of
    func activeEngine(isOwner: Bool) -> CKSyncEngine? {
        isOwner ? privateSyncEngine : sharedSyncEngine
    }

    // MARK: - Public Enqueue APIs

    func enqueueSave(recordID: CKRecord.ID, isOwner: Bool) {
        // A save changes what the record should become, so an evicted delete for the same identity is stale.
        supersedeDroppedBufferEntry(for: recordID, with: .save)
        guard let engine = activeEngine(isOwner: isOwner) else {
            let identity = ScopedRecordIdentity(
                databaseScope: DatabaseScopeResolver.scope(isOwner: isOwner),
                zoneID: recordID.zoneID,
                recordID: recordID,
                familyRecordName: stableFamilyRecordName() ?? appState?.family?.id.recordName ?? recordID.zoneID.zoneName
            )
            bufferSaveIdentity(identity)
            logger.warning("No active sync engine — buffering save for \(recordID.recordName, privacy: .private)")
            return
        }
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        logger
            .info(
                "Enqueued pending save: \(recordID.recordName, privacy: .private) in \(isOwner ? "private" : "shared") database (pending=\(engine.state.pendingRecordZoneChanges.count))"
            )
    }

    /// Batch variant of `enqueueSave` — enqueues each recordID in a tight loop.
    /// Cheap state mutation only; keeps `contributeToBucket`'s N+M saves to one
    /// cache transaction and one logical enqueue pass.
    func batchEnqueueSave(recordIDs: [CKRecord.ID], isOwner: Bool) {
        for recordID in recordIDs {
            enqueueSave(recordID: recordID, isOwner: isOwner)
        }
    }

    /// Re-enqueues both records written by the conditional gem-debit
    /// operation so CKSyncEngine remains the reconciliation path for the
    /// local cache and future server changes.
    func enqueueGemDebit(profileID: CKRecord.ID, ledgerID: CKRecord.ID, isOwner: Bool) {
        enqueueSave(recordID: profileID, isOwner: isOwner)
        enqueueSave(recordID: ledgerID, isOwner: isOwner)
    }

    func dequeueSave(recordID: CKRecord.ID) {
        pendingEnqueueBuffer.withLock { buffer in
            buffer.removeAll { $0.recordID == recordID }
        }
        pendingDeleteBuffer.withLock { buffer in
            buffer.removeAll { $0.recordID == recordID }
        }
        if let privateSyncEngine {
            privateSyncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            privateSyncEngine.state.remove(pendingRecordZoneChanges: [.deleteRecord(recordID)])
        }
        if let sharedSyncEngine {
            sharedSyncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            sharedSyncEngine.state.remove(pendingRecordZoneChanges: [.deleteRecord(recordID)])
        }
    }

    func enqueueDelete(recordID: CKRecord.ID, isOwner: Bool) {
        // A delete changes what the record should become, so an evicted save for the same identity is stale.
        supersedeDroppedBufferEntry(for: recordID, with: .delete)
        // Dangling pending fix: if a save is pending and the underlying cache row is deleted before
        // transmission, the save would forever retry nil from RecordBridge.
        pendingEnqueueBuffer.withLock { buffer in
            buffer.removeAll { $0.recordID == recordID }
        }
        guard let engine = activeEngine(isOwner: isOwner) else {
            let identity = ScopedRecordIdentity(
                databaseScope: DatabaseScopeResolver.scope(isOwner: isOwner),
                zoneID: recordID.zoneID,
                recordID: recordID,
                familyRecordName: stableFamilyRecordName() ?? appState?.family?.id.recordName ?? recordID.zoneID.zoneName
            )
            bufferDeleteIdentity(identity)
            logger.warning("No active sync engine — buffering delete for \(recordID.recordName, privacy: .private)")
            return
        }
        engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
        engine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
        logger.info("Enqueued pending delete: \(recordID.recordName, privacy: .private) in \(isOwner ? "private" : "shared") database")
    }

    // MARK: - Retry Scheduling (fail-closed stall recovery)

    /// WHY backoff retry: transient fetch stalls re-attempt without tight spin.
    func scheduleRetry(for recordID: CKRecord.ID, isOwner: Bool) {
        let key = recordID.recordName
        // Overwrite handling: cancel any existing retry Task for this record before stamping new deadline.
        retryTasks.withLock { tasks in
            tasks[key]?.cancel()
        }
        let attempt = retryAttempts.withLock { counts -> Int in
            let next = (counts[key] ?? 0) + 1
            counts[key] = min(next, AppConstants.CloudKit.backoffScheduleNanos.count)
            return next
        }
        // Stamp 30s retry deadline so engine will re-attempt rather than spin.
        retryDeadlines.withLock { $0[key] = Date().addingTimeInterval(30) }
        let backoffNanos = AppConstants.CloudKit.backoffScheduleNanos[safe: attempt - 1] ?? AppConstants.CloudKit.backoffScheduleNanos.last ?? 4_000_000_000
        logger.warning("Scheduling retry for \(recordID.recordName, privacy: .private) attempt \(attempt) backoff \(Double(backoffNanos) / 1_000_000_000)s with 30s deadline")
        let task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: backoffNanos)
            } catch {
                return
            }
            if Task.isCancelled {
                return
            }
            await MainActor.run {
                guard let self else { return }
                if Task.isCancelled {
                    return
                }
                // Skip re-enqueue if retry state was cleared on success while waiting.
                let shouldRetry = self.retryDeadlines.withLock { $0[key] != nil }
                guard shouldRetry else { return }
                self.enqueueSave(recordID: recordID, isOwner: isOwner)
            }
            // Cleanup Task slot if still current.
            self?.retryTasks.withLock { tasks in
                _ = tasks.removeValue(forKey: key)
            }
        }
        retryTasks.withLock { $0[key] = task }
    }

    /// Clears retry state after successful re-evaluation.
    func clearRetryState(for recordID: CKRecord.ID) {
        let key = recordID.recordName
        retryTasks.withLock { tasks in
            tasks[key]?.cancel()
            tasks.removeValue(forKey: key)
        }
        retryAttempts.withLock { _ = $0.removeValue(forKey: key) }
        retryDeadlines.withLock { _ = $0.removeValue(forKey: key) }
    }

    // MARK: - Manual Trigger APIs

    /// Manually triggers a remote fetch pass across active engines.
    func fetchChanges() async {
        guard !isSyncing else {
            logger.info("Fetch changes skipped: sync pass already in progress")
            return
        }
        if privateSyncEngine == nil && sharedSyncEngine == nil {
            initializeEngines()
        }
        guard privateSyncEngine != nil || sharedSyncEngine != nil else {
            logger.info("Fetch changes skipped: no active sync engines initialized")
            postSyncDidComplete(outcome: .failed)
            return
        }
        isSyncing = true
        activeFetchPassScopes.removeAll()
        completedFetchPassScopes.removeAll()
        currentPassHadParseFailures = false
        currentPassHadCacheWriteFailures = false
        passProducedChanges = false
        defer { isSyncing = false }
        do {
            if let privateSyncEngine {
                activeFetchPassScopes.insert(.private)
                try await privateSyncEngine.fetchChanges()
                completedFetchPassScopes.insert(.private)
            }
            if let sharedSyncEngine {
                activeFetchPassScopes.insert(.shared)
                try await sharedSyncEngine.fetchChanges()
                completedFetchPassScopes.insert(.shared)
            }
            lastSyncedAt = Date()
            syncError = nil
            completeSyncPass()
        } catch {
            logger.error("Fetch changes failed: \(error, privacy: .private)")
            syncError = error.localizedDescription
            postSyncDidComplete(outcome: .failed)
        }
    }

    /// Manually triggers a push pass for all queued saves and deletes.
    func sendPendingChanges() async {
        if isSyncing {
            // WHY: optimistic bursts enqueue mid-pass; pendingRecordZoneChanges auto-sends so coalesce quietly.
            logger.debug("Send changes coalesced: sync pass already in progress")
            return
        }
        if let lastSendCompletedAt, Date().timeIntervalSince(lastSendCompletedAt) < Self.sendCoalescingInterval {
            // WHY: back-to-back optimistic sends follow one completed pass; engine auto-sends so skip redundant pass.
            logger.debug("Send changes coalesced: within coalescing window")
            return
        }
        if privateSyncEngine == nil && sharedSyncEngine == nil {
            initializeEngines()
        }
        guard privateSyncEngine != nil || sharedSyncEngine != nil else {
            postSyncDidComplete(outcome: .failed)
            return
        }
        isSyncing = true
        activeFetchPassScopes.removeAll()
        completedFetchPassScopes.removeAll()
        currentPassHadParseFailures = false
        currentPassHadCacheWriteFailures = false
        passProducedChanges = false
        defer {
            isSyncing = false
            lastSendCompletedAt = Date()
        }
        do {
            if let privateSyncEngine {
                try await privateSyncEngine.sendChanges()
            }
            if let sharedSyncEngine {
                try await sharedSyncEngine.sendChanges()
            }
            lastSyncedAt = Date()
            syncError = nil
            completeSyncPass()
        } catch {
            logger.error("Send changes failed: \(error, privacy: .private)")
            syncError = error.localizedDescription
            postSyncDidComplete(outcome: .failed)
        }
        // WHY terminated retry: jetsam before upload still reaches CloudKit via BG task.
        AppDelegate.scheduleSyncProcessingTask()
    }

    // MARK: - Sync Pass Settlement

    func noteChangesProcessed() {
        passProducedChanges = true
    }

    func noteParseFailure() {
        currentPassHadParseFailures = true
    }

    func noteCacheWriteFailure() {
        currentPassHadCacheWriteFailures = true
    }

    /// WHY gated stamp: all active scopes must succeed without errors.
    private func completeSyncPass() {
        // Freshness gating: private scope success must not stamp shared record types.
        if !activeFetchPassScopes.isEmpty,
           activeFetchPassScopes.isSubset(of: completedFetchPassScopes),
           !currentPassHadParseFailures, !currentPassHadCacheWriteFailures
        {
            if let appState {
                let isOwner = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState)
                let storedOwner = appState.isZoneOwner
                if !isOwner, sharedSyncEngine != nil, !completedFetchPassScopes.contains(.shared) {
                    logger.warning(
                        """
                        Cache freshness stamping skipped: participant zone requires shared scope \
                        stored=\(storedOwner) resolved=\(isOwner) \
                        activeScopes=\(self.activeFetchPassScopes), \
                        completedScopes=\(self.completedFetchPassScopes)
                        """
                    )
                } else {
                    stampCacheFreshness(scopes: completedFetchPassScopes)
                }
            } else {
                stampCacheFreshness(scopes: completedFetchPassScopes)
            }
        } else if !activeFetchPassScopes.isEmpty {
            logger.warning(
                """
                Cache freshness stamping skipped: \
                activeScopes=\(self.activeFetchPassScopes), \
                completedScopes=\(self.completedFetchPassScopes), \
                parseFailures=\(self.currentPassHadParseFailures), \
                cacheWriteFailures=\(self.currentPassHadCacheWriteFailures)
                """
            )
        }
        postSyncDidComplete(outcome: passProducedChanges ? .changed : .noChange)
    }

    #if DEBUG
        /// Test-accessible helper to simulate fetch pass settlement with explicit scopes and error flags.
        func simulateFetchPassSettlement(
            activeScopes: Set<CKDatabase.Scope> = [.private, .shared],
            completedScopes: Set<CKDatabase.Scope> = [.private, .shared],
            hasParseFailures: Bool? = nil,
            hasCacheWriteFailures: Bool? = nil
        ) {
            activeFetchPassScopes = activeScopes
            completedFetchPassScopes = completedScopes
            if let hasParseFailures {
                currentPassHadParseFailures = hasParseFailures
            }
            if let hasCacheWriteFailures {
                currentPassHadCacheWriteFailures = hasCacheWriteFailures
            }
            completeSyncPass()
        }
    #endif

    /// Stamps the cache-freshness watermark across every cached entity type for
    /// the active family, marking the local store as fully hydrated after a
    /// successful `CKSyncEngine` full-sync pass.
    private func stampCacheFreshness(scopes: Set<CKDatabase.Scope> = []) {
        guard let appState,
              let familyRecordName = appState.family?.id.recordName,
              let cacheService = appState.cacheService
        else { return }
        let effectiveScopes = scopes.isEmpty ? completedFetchPassScopes : scopes
        guard !effectiveScopes.isEmpty else {
            logger.warning("Cache freshness stamping skipped: effectiveScopes is empty")
            return
        }
        for type in CachedRecordType.allCases where !type.fetchScopes.isDisjoint(with: effectiveScopes) {
            for scope in effectiveScopes where type.fetchScopes.contains(scope) {
                cacheService.markCacheFresh(familyRecordName: familyRecordName, type: type, scope: scope)
            }
        }
    }

    /// Per-type freshness stamping for partial snapshot reconciliation.
    /// Only the succeeded record types are marked fresh; failed types keep
    /// their existing staleness so the next pass re-fetches them.
    func stampFreshness(for types: Set<CachedRecordType>, scopes: Set<CKDatabase.Scope>) {
        guard let appState,
              let familyRecordName = appState.family?.id.recordName,
              let cacheService = appState.cacheService
        else { return }
        let effectiveScopes = scopes.isEmpty ? completedFetchPassScopes : scopes
        guard !effectiveScopes.isEmpty else {
            logger.warning("Cache freshness stamping skipped: effectiveScopes is empty")
            return
        }
        for type in types where !type.fetchScopes.isDisjoint(with: effectiveScopes) {
            for scope in effectiveScopes where type.fetchScopes.contains(scope) {
                cacheService.markCacheFresh(familyRecordName: familyRecordName, type: type, scope: scope)
            }
        }
    }

    private func postSyncDidComplete(outcome: SyncOutcome) {
        NotificationCenter.default.post(
            name: .syncDidComplete,
            object: self,
            userInfo: [SyncOutcome.userInfoKey: outcome]
        )
    }

    // MARK: - State Serialization Persistence

    func saveState(_ serialization: CKSyncEngine.State.Serialization, for scope: CKDatabase.Scope) {
        guard let key = stateKey(for: scope) else {
            logger.info("saveState skipped: no active family identity to scope CKSyncEngine state")
            return
        }
        do {
            let data = try PropertyListEncoder().encode(serialization)
            defaults.set(data, forKey: key)
        } catch {
            logger.error("Failed to encode CKSyncEngine.State.Serialization for \(String(describing: scope)): \(error, privacy: .private)")
        }
    }

    func loadState(for scope: CKDatabase.Scope) -> CKSyncEngine.State.Serialization? {
        if let key = stateKey(for: scope), let data = defaults.data(forKey: key) {
            do {
                return try PropertyListDecoder().decode(
                    CKSyncEngine.State.Serialization.self,
                    from: data
                )
            } catch {
                logger.error(
                    "Failed to decode CKSyncEngine.State.Serialization for \(String(describing: scope)): \(error, privacy: .private)"
                )
            }
        }
        if let profileName = appState?.currentProfile?.id.recordName {
            let legacyKey = "ck_sync_engine_state.\(profileName).\(scope == .private ? "private" : "shared")"
            if let data = defaults.data(forKey: legacyKey) {
                do {
                    let decoded = try PropertyListDecoder().decode(
                        CKSyncEngine.State.Serialization.self,
                        from: data
                    )
                    if let stableKey = stateKey(for: scope) {
                        defaults.set(data, forKey: stableKey)
                    }
                    return decoded
                } catch {
                    logger.error(
                        "Failed to decode legacy profile CKSyncEngine state for \(String(describing: scope)): \(error, privacy: .private)"
                    )
                }
            }
        }
        let unscopedKey = scope == .private ? "ck_sync_engine_state_private" : "ck_sync_engine_state_shared"
        if let data = defaults.data(forKey: unscopedKey) {
            do {
                let decoded = try PropertyListDecoder().decode(
                    CKSyncEngine.State.Serialization.self,
                    from: data
                )
                if let stableKey = stateKey(for: scope) {
                    defaults.set(data, forKey: stableKey)
                }
                return decoded
            } catch {
                logger.error(
                    "Failed to decode unscoped CKSyncEngine state for \(String(describing: scope)): \(error, privacy: .private)"
                )
            }
        }
        return nil
    }

    func resetState(forAccountID explicitAccountID: String? = nil) {
        if let explicitAccountID {
            defaults.removeObject(forKey: "ck_sync_engine_state.\(explicitAccountID).private")
            defaults.removeObject(forKey: "ck_sync_engine_state.\(explicitAccountID).shared")
            defaults.removeObject(forKey: "ck_sync_engine_state_private")
            defaults.removeObject(forKey: "ck_sync_engine_state_shared")
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("cache_fresh_\(explicitAccountID)_") {
                defaults.removeObject(forKey: key)
            }
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("ck_buffer_overflow.") {
                defaults.removeObject(forKey: key)
            }
            privateSyncEngine = nil
            sharedSyncEngine = nil
            lastSyncedAt = nil
            syncError = nil
            lastPushReceivedAt = nil
            lastChangeReceivedAt = nil
            clearBufferOverflow()
            logger.info("CKSyncEngine state reset for both private and shared databases (account: \(explicitAccountID, privacy: .private))")
            return
        }

        if let stableName = stableFamilyRecordName() {
            defaults.removeObject(forKey: "ck_sync_engine_state.\(stableName).private")
            defaults.removeObject(forKey: "ck_sync_engine_state.\(stableName).shared")
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("cache_fresh_\(stableName)_") {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.removeObject(forKey: "ck_sync_engine_state_private")
        defaults.removeObject(forKey: "ck_sync_engine_state_shared")
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("ck_sync_engine_state.") || key.hasPrefix("cache_fresh_") || key.hasPrefix("ck_buffer_overflow.") {
            defaults.removeObject(forKey: key)
        }

        privateSyncEngine = nil
        sharedSyncEngine = nil
        lastSyncedAt = nil
        syncError = nil
        lastPushReceivedAt = nil
        lastChangeReceivedAt = nil
        clearBufferOverflow()
        let logID = stableFamilyRecordName() ?? appState?.currentProfile?.id.recordName ?? "none"
        logger.info("CKSyncEngine state reset for both private and shared databases (account: \(logID, privacy: .private))")
    }

    // MARK: - Push Tracking

    /// Records the time of the last inbound push or reconciliation pass.
    /// Called from `CKSyncEngineDelegateHandler.handleIncomingZoneChanges`
    /// and `AppLifecycleCoordinator.reconcileCacheFromCloudKit` completion.
    func notePushReceived(at date: Date = Date()) {
        lastPushReceivedAt = date
    }

    /// Display-only marker for engine-delivered changes; independent of push/reconcile age and never stamps freshness.
    func noteChangeReceived(at date: Date = Date()) {
        lastChangeReceivedAt = date
    }
}
