//
//  SceneDelegate.swift
//  LootList
//
//  Created by Ben Mackin on 8/6/26.
//

import UIKit

@MainActor
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    private var appState: AppState? {
        AppDependencies.shared?.appState
    }

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
        Task { [appState] in
            await appState?.authStateMachine.send(.accountChanged)
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
        Task { [appState] in
            await appState?.authStateMachine.transition(.accountChanged)
        }
    }
}
