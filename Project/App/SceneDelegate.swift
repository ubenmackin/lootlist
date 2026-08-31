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

    func sceneWillEnterForeground(_: UIScene) {
        // Foreground watermark catch-up: re-entering foreground re-validates freshness
        // via AppLifecycleCoordinator.performForegroundSync; any missed silent pushes
        // re-deliver through persisted CKSyncEngine change tokens.
        Task { @MainActor in
            await AppDependencies.shared?.lifecycleCoordinator.performForegroundSync()
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
