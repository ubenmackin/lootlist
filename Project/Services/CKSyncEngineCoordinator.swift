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

/// Manages `CKSyncEngine` instances across private and shared database scopes,
/// orchestrating local-first state persistence and sync execution.
@MainActor
@Observable
final class CKSyncEngineCoordinator {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "LootList",
        category: "CKSyncEngineCoordinator"
    )

    // MARK: - State Key Resolution

    /// Resolves the stable family identifier that scopes persisted engine state.
    /// Uses the active zone name when available (set during engine initialization)
    /// falling back to the in-memory family record name. This avoids coupling
    /// the key to the mutable profile identity which can change after dedupe reuse.
    private func stableFamilyRecordName() -> String? {
        if let zoneName = cloudKitService.activeFamilyZoneID?.zoneName, !zoneName.isEmpty {
            return zoneName
        }
        return appState?.family?.id.recordName
    }

    /// Builds the UserDefaults key for persisted `CKSyncEngine` state.
    /// Keyed by stable family plus database scope so pending saves survive
    /// profile switches and re-onboarding within the same family.
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

    /// Weak session reference used to resolve the active family for the
    /// cache-freshness watermark after a full-sync pass. Kept weak (like the
    /// delegate's) to avoid retaining the app root from the long-lived engine.
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

    var isSyncing: Bool = false
    var lastSyncedAt: Date?
    var syncError: String?

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
        // Tests run without entitlements — never instantiate real CKSyncEngine
        // with a live container in unit tests, even if authStatus is
        // authenticated (e.g. via a seeded Mock AppState).
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
        cloudKitService.activeIsOwner = appState.isZoneOwner
        setupEngines()
    }

    @available(*, deprecated, message: "Use init parameter instead")
    func setAppState(_ appState: AppState) {
        self.appState = appState
    }

    private func setupEngines() {
        guard !TestEnvironment.isRunningUnitOrUITests else {
            logger.info("CKSyncEngine setup skipped: unit test environment")
            return
        }
        guard let ckConcrete = cloudKitService as? CloudKitService else { return }
        let container = ckConcrete.container

        if privateSyncEngine == nil {
            let privateSavedState = loadState(for: .private)
            let privateConfig = CKSyncEngine.Configuration(
                database: container.privateCloudDatabase,
                stateSerialization: privateSavedState,
                delegate: delegateHandler
            )
            privateSyncEngine = CKSyncEngine(privateConfig)
        }

        if sharedSyncEngine == nil {
            let sharedSavedState = loadState(for: .shared)
            let sharedConfig = CKSyncEngine.Configuration(
                database: container.sharedCloudDatabase,
                stateSerialization: sharedSavedState,
                delegate: delegateHandler
            )
            sharedSyncEngine = CKSyncEngine(sharedConfig)
        }
        drainPendingEnqueueBuffers()
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

    func activeEngine(isOwner: Bool) -> CKSyncEngine? {
        isOwner ? privateSyncEngine : sharedSyncEngine
    }

    // MARK: - Public Enqueue APIs

    func enqueueSave(recordID: CKRecord.ID, isOwner: Bool) {
        guard let engine = activeEngine(isOwner: isOwner) else {
            let identity = ScopedRecordIdentity(
                databaseScope: isOwner ? .private : .shared,
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

    /// Re-enqueues both records written by the conditional gem-debit
    /// operation so CKSyncEngine remains the reconciliation path for the
    /// local cache and future server changes.
    func enqueueGemDebit(profileID: CKRecord.ID, ledgerID: CKRecord.ID, isOwner: Bool) {
        enqueueSave(recordID: profileID, isOwner: isOwner)
        enqueueSave(recordID: ledgerID, isOwner: isOwner)
    }

    func enqueueDelete(recordID: CKRecord.ID, isOwner: Bool) {
        // Dangling pending fix: if a save is pending and the underlying cache
        // row is deleted before transmission, the save would forever retry nil
        // from RecordBridge. Nil-out any pending save so the delete is canonical.
        // Callers must only enqueue after CONFIRMED local deletion — a nil from
        // RecordBridge.record(for:) alone can mean family/scope validation or a
        // fetch failure on a live row; gate ambiguous cases through
        // RecordBridge.confirmedLocalDeletion instead of deleting server-side.
        pendingEnqueueBuffer.withLock { buffer in
            buffer.removeAll { $0.recordID == recordID }
        }
        guard let engine = activeEngine(isOwner: isOwner) else {
            let identity = ScopedRecordIdentity(
                databaseScope: isOwner ? .private : .shared,
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

    func fetchChanges() async {
        guard !isSyncing else {
            logger.info("Fetch changes skipped: sync pass already in progress")
            return
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

    func sendPendingChanges() async {
        guard !isSyncing else {
            logger.info("Send changes skipped: sync pass already in progress")
            return
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

    /// Finalizes a sync pass: stamps freshness only when all active scopes
    /// succeed — §2 gating prevents private-only success stamping shared types.
    private func completeSyncPass() {
        // §2 freshness gating: private-only must not stamp shared types.
        // Prevents empty hero list when shared scope never completed.
        if activeFetchPassScopes.isSubset(of: completedFetchPassScopes),
           !currentPassHadParseFailures, !currentPassHadCacheWriteFailures
        {
            if let appState, !appState.isZoneOwner, sharedSyncEngine != nil, !completedFetchPassScopes.contains(.shared) {
                logger.warning(
                    """
                    Cache freshness stamping skipped: participant zone requires shared scope \
                    activeScopes=\(self.activeFetchPassScopes), \
                    completedScopes=\(self.completedFetchPassScopes)
                    """
                )
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
            for type in CachedRecordType.allCases {
                cacheService.markCacheFresh(familyRecordName: familyRecordName, type: type)
            }
            return
        }
        for type in CachedRecordType.allCases where !type.fetchScopes.isDisjoint(with: effectiveScopes) {
            for scope in effectiveScopes where type.fetchScopes.contains(scope) {
                cacheService.markCacheFresh(familyRecordName: familyRecordName, type: type, scope: scope)
            }
            cacheService.markCacheFresh(familyRecordName: familyRecordName, type: type)
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
            privateSyncEngine = nil
            sharedSyncEngine = nil
            lastSyncedAt = nil
            syncError = nil
            logger.info("CKSyncEngine state reset for both private and shared databases (account: \(explicitAccountID, privacy: .private))")
            return
        }

        if let stableName = stableFamilyRecordName() {
            defaults.removeObject(forKey: "ck_sync_engine_state.\(stableName).private")
            defaults.removeObject(forKey: "ck_sync_engine_state.\(stableName).shared")
        }
        defaults.removeObject(forKey: "ck_sync_engine_state_private")
        defaults.removeObject(forKey: "ck_sync_engine_state_shared")
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("ck_sync_engine_state.") {
            defaults.removeObject(forKey: key)
        }

        privateSyncEngine = nil
        sharedSyncEngine = nil
        lastSyncedAt = nil
        syncError = nil
        let logID = stableFamilyRecordName() ?? appState?.currentProfile?.id.recordName ?? "none"
        logger.info("CKSyncEngine state reset for both private and shared databases (account: \(logID, privacy: .private))")
    }
}
