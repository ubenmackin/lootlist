//
//  AppLifecycleCoordinator.swift
//  LootList
//
//  Centralizes all startup lifecycle orchestration to prevent duplicate
//  concurrent execution from multiple task/view sites.
//

import CloudKit
import Foundation
import os

@MainActor
@Observable
final class AppLifecycleCoordinator {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "LootList",
        category: "AppLifecycleCoordinator"
    )

    private var isBootstrapInFlight = false
    private var isForegroundSyncInFlight = false
    private var isZoneChangeInFlight = false
    private var hasCompletedInitialBootstrap = false

    private weak var appState: AppState?
    private weak var syncCoordinator: CKSyncEngineCoordinator?
    private weak var appSyncCoordinator: AppSyncCoordinator?
    private weak var dataMigrationsCoordinator: DataMigrationsCoordinator?
    private weak var autoPayoutCoordinator: AutoPayoutCoordinator?
    private let cloudKitService: any CloudKitServiceProtocol

    init(
        appState: AppState,
        cloudKitService: any CloudKitServiceProtocol,
        syncCoordinator: CKSyncEngineCoordinator,
        appSyncCoordinator: AppSyncCoordinator,
        dataMigrationsCoordinator: DataMigrationsCoordinator,
        autoPayoutCoordinator: AutoPayoutCoordinator
    ) {
        self.appState = appState
        self.cloudKitService = cloudKitService
        self.syncCoordinator = syncCoordinator
        self.appSyncCoordinator = appSyncCoordinator
        self.dataMigrationsCoordinator = dataMigrationsCoordinator
        self.autoPayoutCoordinator = autoPayoutCoordinator
    }

    /// Runs the full initial bootstrap sequence exactly once. Subsequent calls
    /// are no-ops while one is in flight or after the initial bootstrap completes.
    /// Call from the app root `.task` modifier only.
    func performInitialBootstrap() async {
        guard !isBootstrapInFlight, !hasCompletedInitialBootstrap else {
            logger.info("Bootstrap skipped: inFlight=\(self.isBootstrapInFlight), completed=\(self.hasCompletedInitialBootstrap)")
            return
        }
        isBootstrapInFlight = true
        defer {
            isBootstrapInFlight = false
        }

        logger.info("Starting initial bootstrap sequence")

        // 1. CloudKit availability check
        await checkCloudKitAccountStatus()

        // 2. Process abandoned zones queue
        if let appState {
            await cloudKitService.processAbandonedZonesQueue(appState: appState)
        }

        // 3. Session restoration
        await appState?.restoreSession(cloudKit: cloudKitService)

        // 4. CKSyncEngine sync pass
        syncCoordinator?.initializeEngines()
        await syncCoordinator?.fetchChanges()
        await syncCoordinator?.sendPendingChanges()

        // 5. Subscription registration
        if let zoneID = appState?.familyZoneID {
            let db = cloudKitService.database(isOwner: appState?.isZoneOwner ?? false)
            await appSyncCoordinator?.registerSubscriptions(for: zoneID, in: db)
        }

        // 6. Data migrations (only when account and family are authenticated)
        if let accountID = appState?.currentProfile?.id.recordName ?? appState?.family?.id.recordName,
           let familyRecordName = appState?.family?.id.recordName
        {
            await dataMigrationsCoordinator?.runPendingMigrations(
                accountID: accountID,
                familyRecordName: familyRecordName
            )
        }

        // 7. Payout processing
        await autoPayoutCoordinator?.processPendingPayoutsIfDue()
        AppDelegate.scheduleWeeklyPayoutRefresh(payoutDay: appState?.family?.payoutDay ?? .sunday)

        hasCompletedInitialBootstrap = true
        logger.info("Initial bootstrap sequence completed successfully")
    }

    private func checkCloudKitAccountStatus() async {
        guard !TestEnvironment.isRunningUnitOrUITests else { return }
        let container = CloudKitService.defaultContainer
        do {
            let status = try await container.accountStatus()
            switch status {
            case .available:
                break
            case .noAccount, .restricted, .couldNotDetermine, .temporarilyUnavailable:
                logger.warning("CloudKit account status is \(String(describing: status))")
            @unknown default:
                break
            }
        } catch {
            logger.error("CloudKit availability check failed: \(error, privacy: .private)")
        }
    }

    /// Lightweight re-sync for scene activation.
    /// Does NOT re-run migrations, bootstrap, or payouts. Guarded against in-flight and requires completed bootstrap.
    func performForegroundSync() async {
        guard hasCompletedInitialBootstrap, !isBootstrapInFlight, !isForegroundSyncInFlight else {
            logger.info("Foreground sync skipped: completed=\(self.hasCompletedInitialBootstrap), inFlight=\(self.isForegroundSyncInFlight)")
            return
        }
        isForegroundSyncInFlight = true
        defer { isForegroundSyncInFlight = false }

        logger.info("Starting foreground sync")
        await syncCoordinator?.fetchChanges()
        await syncCoordinator?.sendPendingChanges()
        logger.info("Foreground sync completed")
    }

    /// User-initiated manual sync (e.g. "Sync Now" in settings or pull-to-refresh).
    func performManualSync() async {
        guard !isBootstrapInFlight, !isForegroundSyncInFlight else {
            logger.info("Manual sync skipped: bootstrap=\(self.isBootstrapInFlight), sync=\(self.isForegroundSyncInFlight)")
            return
        }
        isForegroundSyncInFlight = true
        defer { isForegroundSyncInFlight = false }

        logger.info("Starting manual sync")
        await syncCoordinator?.fetchChanges()
        await syncCoordinator?.sendPendingChanges()
        logger.info("Manual sync completed")
    }

    /// Re-registers subscriptions and re-runs migrations/payouts when the
    /// active family zone changes. Guarded against in-flight and requires completed bootstrap.
    func performFamilyZoneChange() async {
        guard hasCompletedInitialBootstrap, !isBootstrapInFlight, !isZoneChangeInFlight else {
            logger.info("Family zone change skipped: completed=\(self.hasCompletedInitialBootstrap), inFlight=\(self.isZoneChangeInFlight)")
            return
        }
        isZoneChangeInFlight = true
        defer { isZoneChangeInFlight = false }

        guard let zoneID = appState?.familyZoneID else { return }
        let db = cloudKitService.database(isOwner: appState?.isZoneOwner ?? false)
        await appSyncCoordinator?.registerSubscriptions(for: zoneID, in: db)

        if let accountID = appState?.currentProfile?.id.recordName ?? appState?.family?.id.recordName,
           let familyRecordName = appState?.family?.id.recordName
        {
            await dataMigrationsCoordinator?.runPendingMigrations(
                accountID: accountID,
                familyRecordName: familyRecordName
            )
        }

        await autoPayoutCoordinator?.processPendingPayoutsIfDue()
        AppDelegate.scheduleWeeklyPayoutRefresh(payoutDay: appState?.family?.payoutDay ?? .sunday)
    }

    /// Handles incoming remote push notification sync triggers.
    func handleRemoteNotification() async {
        guard hasCompletedInitialBootstrap, !isBootstrapInFlight, !isForegroundSyncInFlight else {
            logger.info("Remote sync skipped: completed=\(self.hasCompletedInitialBootstrap), inFlight=\(self.isForegroundSyncInFlight)")
            return
        }
        isForegroundSyncInFlight = true
        defer { isForegroundSyncInFlight = false }

        await syncCoordinator?.fetchChanges()
        await syncCoordinator?.sendPendingChanges()
    }

    /// Centralized background task handler for weekly payout refresh.
    func handleWeeklyPayoutBackgroundRefresh() async -> Bool {
        await autoPayoutCoordinator?.processPendingPayoutsIfDue()
        let payoutDay = appState?.family?.payoutDay ?? .sunday
        AppDelegate.scheduleWeeklyPayoutRefresh(payoutDay: payoutDay)
        return true
    }
}
