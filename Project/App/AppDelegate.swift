//
//  AppDelegate.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import BackgroundTasks
import CloudKit
import os
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
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "AppDelegate")

    func application(
        _: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        registerBackgroundTasks()
        // Local banners are surfaced by UNUserNotificationCenter, separate from
        // the silent-push path handled in `didReceiveRemoteNotification`.
        // Installing the router makes banners tappable in the foreground and
        // turns taps into tab navigation / inline review actions.
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        return true
    }

    private func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.weeklyPayoutTaskId, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else { return }
            Self.handleWeeklyPayoutBackgroundRefresh(task: refreshTask)
        }
    }

    static func scheduleWeeklyPayoutRefresh(payoutDay: PayoutDay = .sunday) {
        #if targetEnvironment(simulator) || os(macOS)
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
                // Background cold start before AppDependencies is constructed:
                // the family's payout day cannot be resolved and no payout work
                // can run. Report the task as failed rather than claiming success
                // for work that never happened; the next foreground launch
                // (LootListApp) re-arms the refresh with the family's day.
                task.setTaskCompleted(success: false)
                return
            }

            let success = await shared.lifecycleCoordinator.handleWeeklyPayoutBackgroundRefresh()
            task.setTaskCompleted(success: success)
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

        Task { @MainActor in
            let syncNotifications = NotificationCenter.default.notifications(named: .syncDidComplete)

            if let lifecycleCoordinator = AppDependencies.shared?.lifecycleCoordinator {
                await lifecycleCoordinator.handleRemoteNotification()
            }

            let outcome: SyncOutcome? = await withTaskGroup(of: SyncOutcome?.self) { group in
                group.addTask {
                    for await notification in syncNotifications {
                        if let value = notification.userInfo?[SyncOutcome.userInfoKey] as? SyncOutcome {
                            return value
                        }
                    }
                    return nil
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(25))
                    return nil
                }
                let first = await group.next()
                group.cancelAll()
                return first ?? nil
            }
            completionHandler((outcome ?? .failed).backgroundFetchResult)
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
