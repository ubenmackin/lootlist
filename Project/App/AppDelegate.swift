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
        Task {
            _ = await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await _ in NotificationCenter.default.notifications(named: .syncDidComplete) {
                        break
                    }
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 25_000_000_000)
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
