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

/// Manages `CKSyncEngine` instances across private and shared database scopes,
/// orchestrating local-first state persistence and sync execution.
@MainActor
@Observable
final class CKSyncEngineCoordinator {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "LootList",
        category: "CKSyncEngineCoordinator"
    )

    private func stateKey(for scope: CKDatabase.Scope) -> String? {
        guard let accountID = appState?.currentProfile?.id.recordName ?? appState?.family?.id.recordName else {
            return nil
        }
        return (scope == .private) ? "ck_sync_engine_state.\(accountID).private" : "ck_sync_engine_state.\(accountID).shared"
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

    /// Tracks whether engine events during the current pass actually moved data.
    /// Set by the delegate handler and read when the pass settles to derive a
    /// truthful `.changed`/`.noChange` outcome for `.syncDidComplete`.
    @ObservationIgnored private var passProducedChanges = false

    /// Tracks active database scopes executing in the current fetch pass.
    /// Freshness is only stamped after all active scopes complete with zero parse or write failures.
    @ObservationIgnored private var activeFetchPassScopes: Set<CKDatabase.Scope> = []
    @ObservationIgnored private var completedFetchPassScopes: Set<CKDatabase.Scope> = []
    @ObservationIgnored private var currentPassHadParseFailures = false
    @ObservationIgnored private var currentPassHadCacheWriteFailures = false

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

        if !TestEnvironment.isRunningUnitOrUITests {
            setupEngines()
        }
    }

    // MARK: - Engine Setup

    func initializeEngines() {
        setupEngines()
    }

    @available(*, deprecated, message: "Use init parameter instead")
    func setAppState(_ appState: AppState) {
        self.appState = appState
    }

    private func setupEngines() {
        guard privateSyncEngine == nil, sharedSyncEngine == nil else { return }
        guard let ckConcrete = cloudKitService as? CloudKitService else { return }
        let container = ckConcrete.container

        // Setup private database engine (for Guild Master family zones)
        let privateSavedState = loadState(for: .private)
        let privateConfig = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: privateSavedState,
            delegate: delegateHandler
        )
        privateSyncEngine = CKSyncEngine(privateConfig)

        // Setup shared database engine (for Hero / Participant accepted shares)
        let sharedSavedState = loadState(for: .shared)
        let sharedConfig = CKSyncEngine.Configuration(
            database: container.sharedCloudDatabase,
            stateSerialization: sharedSavedState,
            delegate: delegateHandler
        )
        sharedSyncEngine = CKSyncEngine(sharedConfig)

        logger.info("CKSyncEngine instances initialized successfully for private and shared databases")
    }

    // MARK: - Active Engine Selection

    func activeEngine(isOwner: Bool) -> CKSyncEngine? {
        isOwner ? privateSyncEngine : sharedSyncEngine
    }

    // MARK: - Public Enqueue APIs

    func enqueueSave(recordID: CKRecord.ID, isOwner: Bool) {
        guard let engine = activeEngine(isOwner: isOwner) else {
            logger.warning("No active sync engine available to enqueue save for \(recordID.recordName, privacy: .private)")
            return
        }

        engine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        logger
            .info(
                "Enqueued pending save: \(recordID.recordName, privacy: .private) in \(isOwner ? "private" : "shared") database (pending=\(engine.state.pendingRecordZoneChanges.count))"
            )
    }

    func enqueueDelete(recordID: CKRecord.ID, isOwner: Bool) {
        guard let engine = activeEngine(isOwner: isOwner) else {
            logger.warning("No active sync engine available to enqueue delete for \(recordID.recordName, privacy: .private)")
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

    /// Records that engine events during the current pass moved data. Invoked
    /// by `CKSyncEngineDelegateHandler` (on the main actor) so the terminal
    /// outcome posted at pass end distinguishes `.changed` from `.noChange`.
    func noteChangesProcessed() {
        passProducedChanges = true
    }

    /// Records that one or more record parse failures occurred during the current pass.
    /// Blocks cache freshness stamping for the pass so bad data does not mark the cache fresh.
    func noteParseFailure() {
        currentPassHadParseFailures = true
    }

    /// Records that a cache persistence failure occurred during the current pass.
    /// Blocks cache freshness stamping so disk errors do not claim successful hydration.
    func noteCacheWriteFailure() {
        currentPassHadCacheWriteFailures = true
    }

    /// Finalizes a sync pass over active engines: stamps the
    /// cache-freshness watermark for the active family if all active scopes
    /// hydrated successfully without errors, then posts `.syncDidComplete`.
    private func completeSyncPass() {
        let isFetchPass = !activeFetchPassScopes.isEmpty
        let allEnginesHydrated = isFetchPass && activeFetchPassScopes.isSubset(of: completedFetchPassScopes)
        let zeroErrors = !currentPassHadParseFailures && !currentPassHadCacheWriteFailures

        if allEnginesHydrated, zeroErrors {
            stampCacheFreshness()
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
    private func stampCacheFreshness() {
        guard let appState,
              let familyRecordName = appState.family?.id.recordName ?? cloudKitService.activeFamilyZoneID?.zoneName,
              let cacheService = appState.cacheService
        else { return }
        for type in CachedRecordType.allCases {
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
            logger.info("saveState skipped: no active account identity in appState to scope CKSyncEngine state")
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
        guard let key = stateKey(for: scope) else { return nil }
        let legacyKey = (scope == .private) ? "ck_sync_engine_state_private" : "ck_sync_engine_state_shared"
        guard let data = defaults.data(forKey: key) ?? defaults.data(forKey: legacyKey) else { return nil }
        do {
            return try PropertyListDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        } catch {
            logger.error("Failed to decode CKSyncEngine.State.Serialization for \(String(describing: scope)): \(error, privacy: .private)")
            return nil
        }
    }

    func resetState(forAccountID explicitAccountID: String? = nil) {
        let accountID = explicitAccountID ?? appState?.currentProfile?.id.recordName ?? appState?.family?.id.recordName
        if let accountID {
            defaults.removeObject(forKey: "ck_sync_engine_state.\(accountID).private")
            defaults.removeObject(forKey: "ck_sync_engine_state.\(accountID).shared")
        }
        defaults.removeObject(forKey: "ck_sync_engine_state_private")
        defaults.removeObject(forKey: "ck_sync_engine_state_shared")
        privateSyncEngine = nil
        sharedSyncEngine = nil
        setupEngines()
        logger.info("CKSyncEngine state reset for both private and shared databases (account: \(accountID ?? "none", privacy: .private))")
    }
}
