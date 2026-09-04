//
//  SceneDelegate.swift
//  LootList
//
//  Created by Ben Mackin on 8/6/26.
//

import CloudKit
import os
import UIKit

@MainActor
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "SceneDelegate")

    func scene(
        _: UIScene,
        willConnectTo _: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            // Invite taps that cold-launch the app arrive in connection options rather than the warm-tap callback.
            forwardShareAcceptance(metadata)
        }
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
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        // The scene owns acceptance while attached, so this is the warm-tap path; the app delegate remains as fallback.
        forwardShareAcceptance(cloudKitShareMetadata)
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

    private func forwardShareAcceptance(_ metadata: CKShare.Metadata) {
        logger.info("Accepted CloudKit share \(metadata.share.recordID.recordName, privacy: .private)")
        // WHY: snapshot before buffering so the replay store never retains the non-Sendable metadata; LootListApp replays the buffer on appear.
        let resolution = InvitationLinkResolution(metadata: metadata)
        ShareAcceptanceBuffer.enqueue(resolution)
        NotificationCenter.default.post(
            name: .cloudKitShareAccepted,
            object: resolution
        )
    }
}
