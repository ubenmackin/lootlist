//
//  AppDelegate.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import UIKit

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
            // Whichever path wins — terminal sync outcome or the 25s timeout —
            // we resume exactly once. A timeout (no terminal outcome) maps to
            // `.failed` so iOS retries the push rather than throttling it.
            // We filter the async stream for notifications that carry the
            // `SyncOutcome.userInfoKey` — a stray / keyless `.syncDidComplete`
            // is not a terminal signal and must not preempt resolution before
            // the 25 s timeout, otherwise iOS may throttle.
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
