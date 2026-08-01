//
//  AppDelegate.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import UIKit

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        true
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
            _ = await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await _ in syncNotifications {
                        break
                    }
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(25))
                }
                await group.next()
                group.cancelAll()
            }
            completionHandler(.newData)
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
