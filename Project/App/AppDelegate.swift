//
//  AppDelegate.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import BackgroundTasks
import CloudKit
import os
import Synchronization
import UIKit
import UserNotifications

extension SyncOutcome {
    /// Maps the sync outcome to the iOS background-fetch result iOS expects so
    /// it can schedule pushes correctly (`.newData` ⇒ data was fetched, `.noData`
    /// ⇒ nothing changed, `.failed` ⇒ something went wrong / timed out).
    var backgroundFetchResult: UIBackgroundFetchResult {
        switch self {
        case .changed: .newData
        case .noChange: .noData
        case .failed: .failed
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {
    static let weeklyPayoutTaskId = "com.volcrypt.lootlist.weeklypayout"
    static let syncTaskId = "com.volcrypt.lootlist.sync"
    private nonisolated static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "AppDelegate")

    func application(
        _: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        registerBackgroundTasks()
        // Delegate is owned by `AppDependencies.notificationRouter`. If the
        // container already exists (e.g., SwiftUI previews/tests), use it;
        // otherwise the container sets the delegate on init.
        if let router = AppDependencies.shared?.notificationRouter {
            UNUserNotificationCenter.current().delegate = router
        }
        return true
    }

    private func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.weeklyPayoutTaskId, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else { return }
            Self.handleWeeklyPayoutBackgroundRefresh(task: refreshTask)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.syncTaskId, using: nil) { task in
            guard let processingTask = task as? BGProcessingTask else { return }
            Self.handleSyncProcessingTask(task: processingTask)
        }
    }

    static func scheduleWeeklyPayoutRefresh(payoutDay: PayoutDay = .sunday) {
        #if targetEnvironment(simulator)
            logger.debug("BGTaskScheduler submit skipped on simulator / macOS platform")
            return
        #elseif os(macOS)
            logger.debug("BGTaskScheduler submit skipped on simulator / macOS platform")
            return
        #else
            let request = BGAppRefreshTaskRequest(identifier: weeklyPayoutTaskId)
            let now = Date()
            let currentWeekStart = WeekMath.startOfWeek(for: now, payoutDay: payoutDay)
            let nextPayoutDate = Calendar.iso8601UTC.date(byAdding: .day, value: 6, to: currentWeekStart) ?? now
            request.earliestBeginDate = nextPayoutDate > now ? nextPayoutDate : now.addingTimeInterval(3600)

            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                logger.debug("Failed to submit BGAppRefreshTask: \(error, privacy: .private)")
            }
        #endif
    }

    private static func handleWeeklyPayoutBackgroundRefresh(task: BGAppRefreshTask) {
        task.expirationHandler = {
            logger.warning("Weekly payout BGAppRefreshTask expired prior to completion")
            // Complete the expired task as failed — an uncompleted task counts
            // as a failure and iOS throttles future background refreshes.
            task.setTaskCompleted(success: false)
        }

        Task { @MainActor in
            guard let shared = AppDependencies.shared else {
                // Background cold start before AppDependencies is constructed: the family's payout day cannot be
                // resolved and no payout work can run.
                task.setTaskCompleted(success: false)
                return
            }

            let success = await shared.lifecycleCoordinator.handleWeeklyPayoutBackgroundRefresh()
            task.setTaskCompleted(success: success)
        }
    }

    static func scheduleSyncProcessingTask() {
        #if targetEnvironment(simulator)
            logger.debug("BGTaskScheduler submit skipped on simulator / macOS platform")
            return
        #elseif os(macOS)
            logger.debug("BGTaskScheduler submit skipped on simulator / macOS platform")
            return
        #else
            let request = BGProcessingTaskRequest(identifier: syncTaskId)
            request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 15)
            request.requiresNetworkConnectivity = true
            request.requiresExternalPower = false

            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                logger.debug("Failed to submit BGProcessingTask: \(error, privacy: .private)")
            }
        #endif
    }

    private static func handleSyncProcessingTask(task: BGProcessingTask) {
        // WHY: terminated-push coverage — retries pending uploads when silent pushes are throttled or jetsam kills app before sync.
        let expired = Mutex(false)
        var syncTask: Task<Void, Never>?
        task.expirationHandler = {
            logger.warning("Sync BGProcessingTask expired prior to completion")
            expired.withLock { $0 = true }
            syncTask?.cancel()
            task.setTaskCompleted(success: false)
        }

        syncTask = Task { @MainActor in
            guard let shared = AppDependencies.shared else {
                guard !expired.withLock({ $0 }) else { return }
                task.setTaskCompleted(success: false)
                return
            }

            await shared.lifecycleCoordinator.performManualSync()
            guard !expired.withLock({ $0 }) else { return }
            task.setTaskCompleted(success: true)
        }
    }

    func application(
        _: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options _: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
        config.delegateClass = SceneDelegate.self
        return config
    }

    func application(
        _: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        if let dict = userInfo as? [String: NSObject],
           let notification = CKNotification(fromRemoteNotificationDictionary: dict)
        {
            NotificationCenter.default.post(
                name: .cloudKitNotificationReceived,
                object: notification
            )
        }

        // Distinguishable race results: both arms yield a non-nil value so the for-await loop always
        // terminates when either side finishes — a bare Optional here would treat the 25s deadline's `nil` as
        enum RemoteSyncRace: Sendable {
            case completed(SyncOutcome)
            case deadlineExpired
        }

        Task { @MainActor in
            let syncNotifications = NotificationCenter.default.notifications(named: .syncDidComplete)

            let raceResult = await withTaskGroup(of: RemoteSyncRace.self) { group in
                group.addTask {
                    for await notification in syncNotifications {
                        if let value = notification.userInfo?[SyncOutcome.userInfoKey] as? SyncOutcome {
                            return .completed(value)
                        }
                    }
                    return .deadlineExpired
                }
                group.addTask {
                    do {
                        try await Task.sleep(for: .seconds(25))
                    } catch {
                        Self.logger.debug("Background task deadline timer interrupted: \(error, privacy: .private)")
                    }
                    return .deadlineExpired
                }

                Task {
                    if let lifecycleCoordinator = AppDependencies.shared?.lifecycleCoordinator {
                        await lifecycleCoordinator.handleRemoteNotification()
                    }
                }

                var winner: RemoteSyncRace = .deadlineExpired
                for await result in group {
                    winner = result
                    break
                }
                // Whichever side wins the race (sync outcome or the 25s deadline), the other child must be cancelled
                // so the group unwinds instead of blocking forever on the notification stream.
                group.cancelAll()
                return winner
            }
            switch raceResult {
            case let .completed(outcome):
                completionHandler(outcome.backgroundFetchResult)
            case .deadlineExpired:
                // WHY: terminated-push coverage — if the 25s push sync races
                // past its deadline (jetsam / throttled push), schedule the
                // BGProcessingTask retry so pendingRecordZoneChanges still
                // upload when the system next launches the app.
                Self.scheduleSyncProcessingTask()
                completionHandler(.failed)
            }
        }
    }

    func application(
        _: UIApplication,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        NotificationCenter.default.post(
            name: .cloudKitShareAccepted,
            object: cloudKitShareMetadata
        )
    }
}
