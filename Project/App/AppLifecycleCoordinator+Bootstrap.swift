//
//  AppLifecycleCoordinator+Bootstrap.swift
//  LootList
//
//  Created by Ben Mackin on 8/17/26.
//

import CloudKit
import Foundation
import os

// MARK: - Bootstrap Sequence

@MainActor
extension AppLifecycleCoordinator {
    /// Runs the full initial bootstrap sequence exactly once. Subsequent calls
    /// are no-ops while one is in flight or after the initial bootstrap completes.
    /// Call from the app root `.task` modifier only.
    func performInitialBootstrap() async {
        guard tryEnterBootstrap() else {
            let completed = state.withLock { $0.hasCompletedInitialBootstrap }
            let phase = state.withLock { $0.phase }
            logger.info("Bootstrap skipped: phase=\(String(describing: phase)), completed=\(completed)")
            return
        }
        defer {
            exitPhase(.bootstrapping)
        }

        logger.info("Starting initial bootstrap sequence")

        await refreshCloudAccountStatus()

        if let appState {
            await cloudKitService.processAbandonedZonesQueue(appState: appState)
        }

        await appState?.restoreSession(cloudKit: cloudKitService)

        if let cache = appState?.cacheService {
            await cache.bootstrapBackgroundWriterIfNeeded()
            if let writer = cache.backgroundWriter {
                if appState?.backgroundCacheActor == nil {
                    appState?.backgroundCacheActor = writer
                }
                if let concrete = syncCoordinator as? CKSyncEngineCoordinator {
                    concrete.delegateHandler.setBackgroundCache(writer)
                }
            }
        }

        // Initialize sync engines before any operation that may enqueue saves
        // (migrations, payouts, hero seeding) to avoid the nil-engine window.
        if let concrete = syncCoordinator as? CKSyncEngineCoordinator {
            concrete.initializeEngines()
        }

        guard await initializeAndSyncActiveScope() else {
            // Keep bootstrap incomplete without an authenticated family. A
            // recovered session can complete it through the zone-change path.
            let didSchedule = payoutScheduler(appState?.family?.payoutDay ?? .sunday)
            if !didSchedule {
                logger.warning("Bootstrap scheduler failed without an authenticated family scope")
            }
            logger.info("Initial bootstrap paused without an authenticated family scope")
            return
        }

        await reconcileCacheFromCloudKit()

        if let zoneID = appState?.familyZoneID {
            let isOwner = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState)
            let db = cloudKitService.database(isOwner: isOwner)
            await appSyncCoordinator?.registerSubscriptions(for: zoneID, in: db)
        }

        if let accountID = appState?.currentProfile?.id.recordName ?? appState?.family?.id.recordName,
           let familyRecordName = appState?.family?.id.recordName
        {
            await dataMigrationsCoordinator?.runPendingMigrations(
                accountID: accountID,
                familyRecordName: familyRecordName
            )
        }

        // Payout processing — schedule must succeed before marking bootstrap complete.
        await autoPayoutCoordinator?.processPendingPayoutsIfDue()
        let didSchedule = payoutScheduler(appState?.family?.payoutDay ?? .sunday)
        guard didSchedule else {
            logger.warning("Bootstrap not marked completed: payout scheduler failed")
            return
        }

        await evaluateTrophiesCatchup()

        state.withLock { $0.hasCompletedInitialBootstrap = true }
        logger.info("Initial bootstrap sequence completed successfully")
    }

    func initializeAndSyncActiveScope() async -> Bool {
        guard let appState,
              appState.authStatus == .authenticated,
              let family = appState.family,
              let profile = appState.currentProfile,
              let zoneID = appState.familyZoneID,
              family.id.zoneID == zoneID,
              profile.id.zoneID == zoneID,
              profile.family.recordID == family.id,
              let syncCoordinator
        else {
            return false
        }

        handleZoneChangeIfNeeded(currentZoneID: zoneID)

        let isOwner = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState)
        let scopeKey = "\(profile.id.recordName)|\(family.id.recordName)|\(zoneID.zoneName)|\(zoneID.ownerName)|\(isOwner)"
        let enginesNeedInitialization: Bool = {
            if let concrete = syncCoordinator as? CKSyncEngineCoordinator {
                return concrete.activeEngine(isOwner: isOwner) == nil
            }
            return false
        }()
        let shouldInitialize: Bool = state.withLock { flags in
            guard flags.lastSynchronizedScopeKey != scopeKey || enginesNeedInitialization else {
                return false
            }
            return true
        }
        guard shouldInitialize else {
            return true
        }

        await syncCoordinator.fetchChanges()
        await syncCoordinator.sendPendingChanges()
        await reconcileCacheFromCloudKit()
        await evaluateTrophiesCatchup()

        let wrappedZoneID = (zoneName: zoneID.zoneName, ownerName: zoneID.ownerName)
        if let concrete = syncCoordinator as? CKSyncEngineCoordinator, concrete.syncError == nil {
            state.withLock { flags in
                flags.lastSynchronizedScopeKey = scopeKey
                flags.lastObservedZoneID = wrappedZoneID
            }
        } else if syncCoordinator is CKSyncEngineCoordinator == false {
            // Test doubles have no syncError — stamp on success.
            state.withLock { flags in
                flags.lastSynchronizedScopeKey = scopeKey
                flags.lastObservedZoneID = wrappedZoneID
            }
        }
        return true
    }

    /// Refreshes the iCloud account status and publishes the CK-free mirror onto
    /// `appState.cloudAccountStatus`.
    @discardableResult
    func refreshCloudAccountStatus() async -> Bool {
        guard !TestEnvironment.isRunningUnitOrUITests else { return false }
        do {
            let status = try await CloudKitService.defaultContainer.accountStatus()
            appState?.cloudAccountStatus = CloudAccountStatus(status)
            switch status {
            case .available:
                break
            case .noAccount, .restricted, .couldNotDetermine, .temporarilyUnavailable:
                logger.warning("CloudKit account status is \(String(describing: status))")
            @unknown default:
                break
            }
            return true
        } catch {
            logger.error("CloudKit availability check failed: \(error, privacy: .private)")
            return false
        }
    }

    func evaluateTrophiesCatchup() async {
        guard let appState, let profile = appState.currentProfile, let family = appState.family, let achievementService else { return }
        do {
            let awarded = try await achievementService.evaluateAll(for: profile, family: family)
            if !awarded.isEmpty {
                logger.info("Trophy catchup awarded \(awarded.count, privacy: .public) trophies: \(awarded.map(\.name).joined(separator: ", "), privacy: .public)")
            }
        } catch {
            logger.warning("Trophy catchup evaluation failed: \(error, privacy: .private)")
        }
    }
}
