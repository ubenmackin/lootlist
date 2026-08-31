//
//  SceneDelegate.swift
//  LootList
//
//  Created by Ben Mackin on 8/6/26.
//

import UIKit

@MainActor
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(
        _: UIScene,
        willConnectTo _: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if let shortcutItem = connectionOptions.shortcutItem,
           let type = QuickActionType(rawValue: shortcutItem.type)
        {
            NotificationCenter.default.post(
                name: .quickActionTriggered,
                object: type
            )
        }
    }

    func windowScene(
        _: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        if let type = QuickActionType(rawValue: shortcutItem.type) {
            NotificationCenter.default.post(
                name: .quickActionTriggered,
                object: type
            )
            completionHandler(true)
        } else {
            completionHandler(false)
        }
    }
}
