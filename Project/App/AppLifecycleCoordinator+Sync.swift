//
//  AppLifecycleCoordinator+Sync.swift
//  LootList
//
//  Created by Ben Mackin on 8/17/26.
//

import CloudKit
import Foundation
import os

// MARK: - Foreground, Manual & Push Sync

@MainActor
extension AppLifecycleCoordinator {
    /// Lightweight re-sync for scene activation.
    func performForegroundSync() async {
        guard tryEnterSync() else {
            let completed = syncGate.hasCompletedInitialBootstrap
            let phase = syncGate.phase
            logger.info("Foreground sync skipped: completed=\(completed), phase=\(String(describing: phase))")
            return
        }
        defer { exitPhase(.syncing) }

        logger.info("Starting foreground sync")
        await executeCoreSyncSequence()
        await evaluateTrophiesCatchup()
        await autoPayoutCoordinator?.processPendingPayoutsIfDue()
        let didScheduleForegroundPayout = payoutScheduler(appState?.family?.payoutDay ?? .sunday)
        if !didScheduleForegroundPayout {
            logger.warning("Foreground sync: payout scheduler failed")
        }
        logger.info("Foreground sync completed")
    }

    /// User-initiated manual sync.
    func performManualSync() async {
        guard tryEnterManualSync() else {
            let phase = syncGate.phase
            let manual = syncGate.isManualSyncing
            logger.info("Manual sync skipped: phase=\(String(describing: phase)), manualSyncing=\(manual)")
            return
        }
        defer { exitManualSync() }

        logger.info("Starting manual sync")
        if let concrete = syncCoordinator as? CKSyncEngineCoordinator,
           concrete.privateSyncEngine == nil, concrete.sharedSyncEngine == nil
        {
            concrete.initializeEngines()
        }
        await executeCoreSyncSequence()
        await evaluateTrophiesCatchup()
        logger.info("Manual sync completed")
    }

    /// Re-registers subscriptions and re-runs migrations/payouts when the
    /// active family zone changes. Recovered authenticated sessions may complete
    /// this transition before initial bootstrap has been marked complete.
    func performFamilyZoneChange() async {
        let bootstrapIncomplete = !syncGate.hasCompletedInitialBootstrap
        // Hero recovery path: initial bootstrap paused at `detectedPreviousFamily` before authentication — the
        // subsequent `acceptDetectedFamily` sets `familyZoneID`/`.authenticated`.
        if bootstrapIncomplete {
            guard let appState,
                  appState.authStatus == .authenticated,
                  appState.family != nil,
                  appState.currentProfile != nil,
                  appState.familyZoneID != nil
            else {
                logger.info("Family zone change skipped: bootstrap not completed")
                return
            }
        }
        guard tryEnterZoneChange(allowBeforeBootstrap: bootstrapIncomplete) else {
            let completed = syncGate.hasCompletedInitialBootstrap
            let phase = syncGate.phase
            logger.info("Family zone change skipped: completed=\(completed), phase=\(String(describing: phase))")
            return
        }
        defer { exitPhase(.zoneChanging) }

        guard let appState,
              appState.authStatus == .authenticated,
              let zoneID = appState.familyZoneID,
              appState.family != nil,
              appState.currentProfile != nil,
              await initializeAndSyncActiveScope()
        else {
            return
        }

        await reconcileCacheFromCloudKit()

        let isOwner = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState)
        let db = cloudKitService.database(isOwner: isOwner)
        await appSyncCoordinator?.registerSubscriptions(for: zoneID, in: db)

        if let accountID = appState.currentProfile?.id.recordName ?? appState.family?.id.recordName,
           let familyRecordName = appState.family?.id.recordName
        {
            await dataMigrationsCoordinator?.runPendingMigrations(
                accountID: accountID,
                familyRecordName: familyRecordName
            )
        }

        await autoPayoutCoordinator?.processPendingPayoutsIfDue()
        let didScheduleZoneChangePayout = payoutScheduler(appState.family?.payoutDay ?? .sunday)
        if !didScheduleZoneChangePayout {
            logger.warning("Family zone change: payout scheduler failed")
        }

        // If this zone change completed the hero-recovery bootstrap, mark it done
        // so subsequent foreground/remote syncs are not permanently skipped.
        if !syncGate.hasCompletedInitialBootstrap {
            syncGate.markBootstrapComplete()
            logger.info("Family zone change completed initial bootstrap for recovered hero")
        }
    }

    /// Push-triggered sync stays fetch + send + reconcile only.
    func handleRemoteNotification() async {
        guard tryEnterSync() else {
            let completed = syncGate.hasCompletedInitialBootstrap
            let phase = syncGate.phase
            logger.info("Remote sync skipped: completed=\(completed), phase=\(String(describing: phase))")
            return
        }
        defer { exitPhase(.syncing) }

        // WHY: silent pushes run under a tight background budget — trophy catchup and
        // payouts defer to foreground/weekly refresh so push latency buys cache freshness, not jetsam risk.
        await executeCoreSyncSequence()
    }

    /// Centralized background task handler for weekly payout refresh.
    func handleWeeklyPayoutBackgroundRefresh() async -> Bool {
        await autoPayoutCoordinator?.processPendingPayoutsIfDue()
        let payoutDay = appState?.family?.payoutDay ?? .sunday
        let didSchedule = payoutScheduler(payoutDay)
        if !didSchedule {
            logger.warning("Background payout refresh: payout scheduler failed")
        }
        return didSchedule
    }

    /// Shared fetch-send-schedule-reconcile pass for foreground, manual, and push syncs.
    private func executeCoreSyncSequence() async {
        await syncCoordinator?.fetchChanges()
        await syncCoordinator?.sendPendingChanges()
        // WHY: terminated-push coverage complements push-driven sync — schedule
        // BGProcessingTask retry so pendingRecordZoneChanges still upload after
        // jetsam or throttled silent push.
        AppDelegate.scheduleSyncProcessingTask()
        await reconcileCacheFromCloudKit()
    }
}
