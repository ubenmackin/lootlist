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

    /// Legacy profile-keyed state location used before the family-stable migration.
    /// Retained only to source a one-time copy into the new family-keyed key.
    private func legacyProfileStateKey(for scope: CKDatabase.Scope) -> String? {
        guard let profileRecordName = appState?.currentProfile?.id.recordName,
              let familyRecordName = stableFamilyRecordName(),
              profileRecordName != familyRecordName
        else {
            return nil
        }
        return (scope == .private)
            ? "ck_sync_engine_state.\(profileRecordName).private"
            : "ck_sync_engine_state.\(profileRecordName).shared"
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

    // MARK: - Buffered Enqueue

    /// Buffers record identities enqueued before engines are initialized.
    /// Prevents data loss when `enqueueSave`/`enqueueDelete` races engine init
    /// during initial bootstrap or rapid Guild/Hero Settings taps.
    private let pendingEnqueueBuffer = Mutex<[ScopedRecordIdentity]>([])
    private let pendingDeleteRecordNames = Mutex<Set<String>>([])

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
        drainPendingEnqueueBuffers()
    }

    @available(*, deprecated, message: "Use init parameter instead")
    func setAppState(_ appState: AppState) {
        self.appState = appState
    }

    private func setupEngines() {
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
    }

    // MARK: - Buffered Enqueue Helpers

    private func makeScopedIdentity(for recordID: CKRecord.ID, isOwner: Bool) -> ScopedRecordIdentity {
        let scope: CKDatabase.Scope = isOwner ? .private : .shared
        return ScopedRecordIdentity(
            databaseScope: scope,
            zoneID: recordID.zoneID,
            recordID: recordID,
            familyRecordName: stableFamilyRecordName()
        )
    }

    private func drainPendingEnqueueBuffers() {
        // Drain buffer atomically and re-enqueue via proper engine.
        let deleteNames = pendingDeleteRecordNames.withLock { $0 }
        let buffered = pendingEnqueueBuffer.withLock { buffer -> [ScopedRecordIdentity] in
            let copy = buffer
            buffer.removeAll()
            return copy
        }
        // Clear delete tracking for drained identities.
        if !buffered.isEmpty {
            let drainedNames = Set(buffered.map(\.recordName))
            pendingDeleteRecordNames.withLock { $0.subtract(drainedNames) }
        }
        for identity in buffered {
            let isOwner = identity.databaseScope == .private
            let isDelete = deleteNames.contains(identity.recordName)
            guard let engine = activeEngine(isOwner: isOwner) else {
                logger.warning("Drain failed — no engine for buffered \(isDelete ? "delete" : "save") \(identity.recordName, privacy: .private)")
                pendingEnqueueBuffer.withLock { $0.append(identity) }
                if isDelete {
                    _ = pendingDeleteRecordNames.withLock { $0.insert(identity.recordName) }
                }
                continue
            }
            if isDelete {
                engine.state.add(pendingRecordZoneChanges: [.deleteRecord(identity.recordID)])
                logger.info("Drained buffered delete: \(identity.recordName, privacy: .private) in \(isOwner ? "private" : "shared") database")
            } else {
                engine.state.add(pendingRecordZoneChanges: [.saveRecord(identity.recordID)])
                logger
                    .info(
                        "Drained buffered save: \(identity.recordName, privacy: .private) in \(isOwner ? "private" : "shared") database (pending=\(engine.state.pendingRecordZoneChanges.count))"
                    )
            }
        }
    }

    // MARK: - Active Engine Selection

    func activeEngine(isOwner: Bool) -> CKSyncEngine? {
        isOwner ? privateSyncEngine : sharedSyncEngine
    }

    // MARK: - Public Enqueue APIs

    func enqueueSave(recordID: CKRecord.ID, isOwner: Bool) {
        let identity = makeScopedIdentity(for: recordID, isOwner: isOwner)
        // Buffer when engine is not yet available to prevent data loss during bootstrap.
        // Uses Mutex to safely queue identities when enqueue races engine init.
        if activeEngine(isOwner: isOwner) == nil {
            pendingEnqueueBuffer.withLock { $0.append(identity) }
            let pending = self.pendingEnqueueBuffer.withLock { $0.count }
            logger.warning("No active sync engine — buffered save for \(recordID.recordName, privacy: .private) (pending=\(pending))")
            return
        }
        guard let engine = activeEngine(isOwner: isOwner) else {
            // Raced to nil between check and use — re-buffer.
            pendingEnqueueBuffer.withLock { $0.append(identity) }
            logger.warning("No active sync engine available to enqueue save for \(recordID.recordName, privacy: .private) — re-buffered")
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
        let identity = makeScopedIdentity(for: recordID, isOwner: isOwner)
        if activeEngine(isOwner: isOwner) == nil {
            pendingEnqueueBuffer.withLock { $0.append(identity) }
            _ = pendingDeleteRecordNames.withLock { $0.insert(identity.recordName) }
            let pending = self.pendingEnqueueBuffer.withLock { $0.count }
            logger.warning("No active sync engine — buffered delete for \(recordID.recordName, privacy: .private) (pending=\(pending))")
            return
        }
        guard let engine = activeEngine(isOwner: isOwner) else {
            pendingEnqueueBuffer.withLock { $0.append(identity) }
            _ = pendingDeleteRecordNames.withLock { $0.insert(identity.recordName) }
            logger.warning("No active sync engine available to enqueue delete for \(recordID.recordName, privacy: .private) — re-buffered")
            return
        }

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
            postSyncDidComplete(outcome: .noChange)
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
            postSyncDidComplete(outcome: .noChange)
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

    /// Finalizes a sync pass over active engines: stamps the
    /// cache-freshness watermark for the active family if all active scopes
    /// hydrated successfully without errors, then posts `.syncDidComplete`.
    /// Freshness is stamped per-database-scope so a private-only pass never
    /// marks shared data as fresh. When the active family is participant-owned
    /// (`isZoneOwner == false`) the shared scope must have completed; a
    /// private-only success therefore does not stamp shared types, preventing
    /// a subsequent `fetchProfiles` for a shared-DB hero from seeing
    /// `isCacheFresh == true` and returning an empty authoritative result.
    private func completeSyncPass() {
        let isFetchPass = !activeFetchPassScopes.isEmpty
        let allEnginesHydrated = isFetchPass && activeFetchPassScopes.isSubset(of: completedFetchPassScopes)
        let zeroErrors = !currentPassHadParseFailures && !currentPassHadCacheWriteFailures

        if allEnginesHydrated, zeroErrors {
            // Participant-owned families must have fetched the shared scope for
            // any type that is shared-fetchable to be considered fresh. If both
            // engines exist but only private completed, stamping is still gated:
            // we stamp only the scopes that actually completed.
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
        } else if isFetchPass {
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
    /// successful `CKSyncEngine` full-sync pass. This is a device-local
    /// freshness watermark (not a `CKServerChangeToken` cursor): it only asserts
    /// that a full pass completed so `CacheService.isCacheFresh` can gate
    /// cache-first reads.
    /// - Parameter scopes: The database scopes that successfully completed in
    ///   this pass. Only types whose `fetchScopes` intersect `scopes` are
    ///   stamped, so a private-only pass never marks shared data fresh. When
    ///   `scopes` is empty the legacy unscoped stamp is used for backward
    ///   compatibility (tests and single-engine passes).
    private func stampCacheFreshness(scopes: Set<CKDatabase.Scope> = []) {
        // Require an explicit family record to avoid stamping freshness under a zoneName
        // that cache reads do not gate on, which would mark the wrong family as fresh.
        guard let appState,
              let familyRecordName = appState.family?.id.recordName,
              let cacheService = appState.cacheService
        else { return }
        let effectiveScopes = scopes.isEmpty ? completedFetchPassScopes : scopes
        if effectiveScopes.isEmpty {
            // Fallback for non-fetch passes or legacy callers: stamp unscoped keys.
            for type in CachedRecordType.allCases {
                cacheService.markCacheFresh(familyRecordName: familyRecordName, type: type)
            }
            return
        }
        for type in CachedRecordType.allCases {
            // Only stamp types whose fetch scopes intersect the completed scopes.
            // All current family-zone types have fetchScopes == [.private, .shared],
            // so this effectively stamps every type for each completed scope, but
            // future scope-specific types will be filtered correctly.
            let shouldStamp = !type.fetchScopes.isDisjoint(with: effectiveScopes)
            guard shouldStamp else { continue }
            for scope in effectiveScopes where type.fetchScopes.contains(scope) {
                cacheService.markCacheFresh(familyRecordName: familyRecordName, type: type, scope: scope)
            }
            // Also maintain legacy unscoped stamp for backward-compatible readers.
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
        // Priority: new family-keyed > legacy profile-keyed (migrated) > unscoped legacy.
        // Each legacy hit is copied forward to the new key so subsequent loads are stable
        // across profile switches and future writes remain discoverable.
        if let key = stateKey(for: scope), let data = defaults.data(forKey: key) {
            do {
                return try PropertyListDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
            } catch {
                logger.error("Failed to decode CKSyncEngine.State.Serialization for \(String(describing: scope)): \(error, privacy: .private)")
                return nil
            }
        }

        if let legacyProfileKey = legacyProfileStateKey(for: scope), let data = defaults.data(forKey: legacyProfileKey) {
            do {
                let serialization = try PropertyListDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
                // Migrate orphaned profile-keyed state to the stable family key.
                if let newKey = stateKey(for: scope) {
                    defaults.set(data, forKey: newKey)
                }
                return serialization
            } catch {
                logger.error("Failed to decode legacy profile CKSyncEngine.State.Serialization for \(String(describing: scope)): \(error, privacy: .private)")
                return nil
            }
        }

        let legacyKey = (scope == .private) ? "ck_sync_engine_state_private" : "ck_sync_engine_state_shared"
        guard let data = defaults.data(forKey: legacyKey) else { return nil }
        do {
            let serialization = try PropertyListDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
            // Migrate unscoped legacy state to the stable family key when possible.
            if let newKey = stateKey(for: scope) {
                defaults.set(data, forKey: newKey)
            }
            return serialization
        } catch {
            logger.error("Failed to decode legacy unscoped CKSyncEngine.State.Serialization for \(String(describing: scope)): \(error, privacy: .private)")
            return nil
        }
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

        let stableName = stableFamilyRecordName()
        let profileName = appState?.currentProfile?.id.recordName

        if let stableName {
            defaults.removeObject(forKey: "ck_sync_engine_state.\(stableName).private")
            defaults.removeObject(forKey: "ck_sync_engine_state.\(stableName).shared")
        }
        if let profileName, profileName != stableName {
            defaults.removeObject(forKey: "ck_sync_engine_state.\(profileName).private")
            defaults.removeObject(forKey: "ck_sync_engine_state.\(profileName).shared")
        }
        defaults.removeObject(forKey: "ck_sync_engine_state_private")
        defaults.removeObject(forKey: "ck_sync_engine_state_shared")

        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("ck_sync_engine_state.") {
            if key == "ck_sync_engine_state_private" || key == "ck_sync_engine_state_shared" {
                continue
            }
            let isStable = stableName.map { key == "ck_sync_engine_state.\($0).private" || key == "ck_sync_engine_state.\($0).shared" } ?? false
            let isProfile = profileName.map { key == "ck_sync_engine_state.\($0).private" || key == "ck_sync_engine_state.\($0).shared" } ?? false
            if !isStable, !isProfile {
                defaults.removeObject(forKey: key)
            }
        }

        privateSyncEngine = nil
        sharedSyncEngine = nil
        lastSyncedAt = nil
        syncError = nil
        let logID = explicitAccountID ?? stableName ?? profileName ?? "none"
        logger.info("CKSyncEngine state reset for both private and shared databases (account: \(logID, privacy: .private))")
    }
}
