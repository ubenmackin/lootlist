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

/// Manages CKSyncEngine instances across private and shared database scopes.
/// WHY: Pending save/delete buffers are Mutex-guarded so enqueue can race setup/drain without losing mutations; nil engine buffers until authenticated scope resolves.
/// WHY: Deterministic IDs dedupe on recordName; deletes capture ScopedRecordIdentity before invalidation and rely on fail-closed tryFetch.
@MainActor
@Observable
final class CKSyncEngineCoordinator: SyncEnqueuing {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "LootList",
        category: "CKSyncEngineCoordinator"
    )

    // MARK: - State Key Resolution

    /// Resolves stable family identifier scoping engine state (zone name or in-memory ID).
    private func stableFamilyRecordName() -> String? {
        if let zoneName = cloudKitService.activeFamilyZoneID?.zoneName, !zoneName.isEmpty {
            return zoneName
        }
        return appState?.family?.id.recordName
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
    // WHY: Mutex guards pending buffers — enqueue vs drain could interleave and lose identities when engine is nil.
    @ObservationIgnored private let pendingEnqueueBuffer = Mutex<[ScopedRecordIdentity]>([])
    // WHY: Separate delete buffer so a save→delete conversion (dangling pending fix in enqueueDelete) atomically
    // removes from save buffer and appends to delete buffer without losing cross-buffer ordering.
    @ObservationIgnored private let pendingDeleteBuffer = Mutex<[ScopedRecordIdentity]>([])

    var isSyncing: Bool = false
    var lastSyncedAt: Date?
    var syncError: String?
    private(set) var lastPushReceivedAt: Date?

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

    // MARK: - Engine Setup

    func initializeEngines() {
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

        // WHY: owner routing uses Family.creatorUserRecordName anchor via resolvedIsOwner, not role.
        let isOwner = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState)
        let storedOwner = appState.isZoneOwner
        if isOwner != storedOwner {
            logger.warning("CKSyncEngineCoordinator.setupEngines isOwner corrected via creator anchor: stored=\(storedOwner) resolved=\(isOwner)")
        }
        if isOwner {
            if privateSyncEngine == nil {
                privateSyncEngine = makeEngine(for: .private, container: ckConcrete.container)
            }
        } else {
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
                pendingEnqueueBuffer.withLock { $0.append(identity) }
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
                pendingDeleteBuffer.withLock { $0.append(identity) }
            }
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
        guard let engine = activeEngine(isOwner: isOwner) else {
            let identity = ScopedRecordIdentity(
                databaseScope: DatabaseScopeResolver.scope(isOwner: isOwner),
                zoneID: recordID.zoneID,
                recordID: recordID,
                familyRecordName: stableFamilyRecordName() ?? appState?.family?.id.recordName ?? recordID.zoneID.zoneName
            )
            pendingEnqueueBuffer.withLock { $0.append(identity) }
            logger.warning("No active sync engine — buffering save for \(recordID.recordName, privacy: .private)")
            return
        }
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        logger
            .info(
                "Enqueued pending save: \(recordID.recordName, privacy: .private) in \(isOwner ? "private" : "shared") database (pending=\(engine.state.pendingRecordZoneChanges.count))"
            )
    }

    func enqueueRewardEvent(_ event: RewardEvent, isOwner: Bool) {
        enqueueSave(recordID: event.id, isOwner: isOwner)
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

    func enqueueDelete(recordID: CKRecord.ID, isOwner: Bool) {
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
            pendingDeleteBuffer.withLock { $0.append(identity) }
            logger.warning("No active sync engine — buffering delete for \(recordID.recordName, privacy: .private)")
            return
        }
        engine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
        engine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
        logger.info("Enqueued pending delete: \(recordID.recordName, privacy: .private) in \(isOwner ? "private" : "shared") database")
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
        guard !isSyncing else {
            logger.info("Send changes skipped: sync pass already in progress")
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
        defer { isSyncing = false }
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

    /// Stamps freshness watermarks when all active database scopes succeed without errors.
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
            cacheService.markCacheFresh(familyRecordName: familyRecordName, type: type)
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
            cacheService.markCacheFresh(familyRecordName: familyRecordName, type: type)
        }
    }

    /// Convenience overload accepting an ordered collection of types.
    func stampFreshness(for types: [CachedRecordType], scopes: Set<CKDatabase.Scope>) {
        stampFreshness(for: Set(types), scopes: scopes)
    }

    /// Compatibility wrapper for call sites that reference the historic name.
    func stampCacheFreshness(for types: Set<CachedRecordType>, scopes: Set<CKDatabase.Scope>) {
        stampFreshness(for: types, scopes: scopes)
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
            privateSyncEngine = nil
            sharedSyncEngine = nil
            lastSyncedAt = nil
            syncError = nil
            lastPushReceivedAt = nil
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
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("ck_sync_engine_state.") || key.hasPrefix("cache_fresh_") {
            defaults.removeObject(forKey: key)
        }

        privateSyncEngine = nil
        sharedSyncEngine = nil
        lastSyncedAt = nil
        syncError = nil
        lastPushReceivedAt = nil
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
}
