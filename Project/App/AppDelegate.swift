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
    nonisolated static let weeklyPayoutTaskId = "com.volcrypt.lootlist.weeklypayout"
    nonisolated static let syncTaskId = "com.volcrypt.lootlist.sync"
    nonisolated static let spendDigestTaskId = "com.volcrypt.lootlist.spenddigest"
    private nonisolated static let logger = Logger(category: "AppDelegate")

    /// Thread-safe exactly-once completion box for BGTask expiration/finish races.
    /// `BGTask.setTaskCompleted(success:)` is thread-safe from any isolation
    /// domain; the `Mutex` guarantees at-most-once delivery without requiring
    /// a MainActor hop.
    private final class ExactlyOnceCompletion: Sendable {
        private let state = Mutex<Bool>(false)

        func complete(_ task: BGTask, success: Bool) {
            let shouldComplete = state.withLock { done -> Bool in
                guard !done else { return false }
                done = true
                return true
            }
            if shouldComplete {
                task.setTaskCompleted(success: success)
            }
        }
    }

    /// Returns the shared dependencies if available, logging a warning if nil.
    /// Exposed as a seam for unit tests since BGTask cannot be instantiated.
    nonisolated static func resolveDependencies(
        for taskIdentifier: String
    ) -> AppDependencies? {
        guard let shared = AppDependencies.shared else {
            logger.warning("\(taskIdentifier) missing dependencies prior to completion")
            return nil
        }
        return shared
    }

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
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.weeklyPayoutTaskId, using: .main) { task in
            guard let refreshTask = task as? BGAppRefreshTask else { return }
            Self.handleWeeklyPayoutBackgroundRefresh(task: refreshTask)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.syncTaskId, using: .main) { task in
            guard let processingTask = task as? BGProcessingTask else { return }
            Self.handleSyncProcessingTask(task: processingTask)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.spendDigestTaskId, using: .main) { task in
            guard let refreshTask = task as? BGAppRefreshTask else { return }
            Self.handleSpendDigestBackgroundRefresh(task: refreshTask)
        }
    }

    nonisolated static func scheduleWeeklyPayoutRefresh(payoutDay: PayoutDay = .sunday) {
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
            let weekUpperBound = WeekMath.weekRange(starting: currentWeekStart).upperBound
            request.earliestBeginDate = weekUpperBound > now ? weekUpperBound : now.addingTimeInterval(3600)

            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                logger.debug("Failed to submit BGAppRefreshTask: \(error, privacy: .private)")
            }
        #endif
    }

    @MainActor
    private static func handleBackgroundRefresh(
        task: BGTask,
        logPrefix: String,
        work: @escaping @MainActor (AppDependencies) async -> Bool
    ) {
        let taskIdentifier = task.identifier
        let completion = ExactlyOnceCompletion()

        let workTask = Task {
            guard let shared = Self.resolveDependencies(for: taskIdentifier) else {
                completion.complete(task, success: false)
                return
            }

            let success = await work(shared)
            completion.complete(task, success: success)
        }

        task.expirationHandler = {
            logger.warning("\(logPrefix) \(taskIdentifier) expired prior to completion")
            workTask.cancel()
            completion.complete(task, success: false)
        }
    }

    @MainActor
    private static func handleWeeklyPayoutBackgroundRefresh(task: BGAppRefreshTask) {
        handleBackgroundRefresh(task: task, logPrefix: "Weekly payout BGAppRefreshTask") { shared in
            await shared.lifecycleCoordinator.handleWeeklyPayoutBackgroundRefresh()
        }
    }

    nonisolated static func scheduleSpendDigestRefresh(now: Date = Date()) {
        #if targetEnvironment(simulator)
            logger.debug("BGTaskScheduler submit skipped on simulator / macOS platform")
            return
        #elseif os(macOS)
            logger.debug("BGTaskScheduler submit skipped on simulator / macOS platform")
            return
        #else
            let request = BGAppRefreshTaskRequest(identifier: spendDigestTaskId)
            request.earliestBeginDate = SpendDigestService.nextDigestDate(after: now)

            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                logger.debug("Failed to submit spend digest BGAppRefreshTask: \(error, privacy: .private)")
            }
        #endif
    }

    @MainActor
    private static func handleSpendDigestBackgroundRefresh(task: BGAppRefreshTask) {
        handleBackgroundRefresh(task: task, logPrefix: "Spend digest BGAppRefreshTask") { shared in
            let success = await shared.appSyncCoordinator.handleSpendDigestBackgroundRefresh()
            scheduleSpendDigestRefresh()
            return success
        }
    }

    nonisolated static func scheduleSyncProcessingTask() {
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

    @MainActor
    private static func handleSyncProcessingTask(task: BGProcessingTask) {
        // WHY: terminated-push coverage — retries pending uploads when silent pushes are throttled or jetsam kills app before sync.
        handleBackgroundRefresh(task: task, logPrefix: "Sync BGProcessingTask") { shared in
            await shared.lifecycleCoordinator.performManualSync()
            return true
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

    /// Async silent-push resolver backing the completion-handler delegate below.
    /// WHY async extraction: UIKit still requires the completion-handler signature,
    /// so the delegate stays a thin wrapper while the sync race lives in async code
    /// with the BGProcessingTask retry on deadline.
    nonisolated static func resolveSilentPushResult() async -> UIBackgroundFetchResult {
        enum RemoteSyncRace: Sendable {
            case completed(SyncOutcome)
            case deadlineExpired
        }

        let syncNotifications = NotificationCenter.default.notifications(named: .syncDidComplete)

        let raceResult = await withTaskGroup(of: RemoteSyncRace?.self) { group in
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
            group.addTask {
                // WHY: structured child so deadline cancellation propagates into the sync pass instead of orphaning it.
                if let lifecycleCoordinator = AppDependencies.shared?.lifecycleCoordinator {
                    await lifecycleCoordinator.handleRemoteNotification()
                }
                return nil
            }

            var winner: RemoteSyncRace = .deadlineExpired
            for await result in group {
                // WHY: sync completion alone never decides the fetch result; wait for notification or deadline.
                guard let result else { continue }
                winner = result
                break
            }
            // WHY: cancel the loser so the notification stream does not block group teardown.
            group.cancelAll()
            return winner
        }
        switch raceResult {
        case let .completed(outcome):
            return outcome.backgroundFetchResult
        case .deadlineExpired:
            // WHY: terminated-push coverage — if the 25s push sync races
            // past its deadline (jetsam / throttled push), schedule the
            // BGProcessingTask retry so pendingRecordZoneChanges still
            // upload when the system next launches the app.
            Self.scheduleSyncProcessingTask()
            return .failed
        }
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

        Task {
            await completionHandler(Self.resolveSilentPushResult())
        }
    }

    @MainActor
    func application(
        _: UIApplication,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        // WHY: scene owns acceptance when attached, so the app delegate forwards only with no window scene and one tap never double-enqueues.
        guard !UIApplication.shared.connectedScenes.contains(where: { $0 is UIWindowScene }) else { return }
        let resolution = InvitationLinkResolution(metadata: cloudKitShareMetadata)
        ShareAcceptanceBuffer.enqueue(resolution)
        NotificationCenter.default.post(
            name: .cloudKitShareAccepted,
            object: resolution
        )
    }
}
