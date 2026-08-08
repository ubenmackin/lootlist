//
//  QuickActionManager.swift
//  LootList
//
//  Created by Ben Mackin on 8/6/26.
//

import UIKit

enum QuickActionType: String, Sendable {
    case processPayouts = "com.volcrypt.lootlist.processPayouts"
    case addQuickQuest = "com.volcrypt.lootlist.addQuickQuest"
    case addTemplate = "com.volcrypt.lootlist.addTemplate"
    case addTransaction = "com.volcrypt.lootlist.addTransaction"
    case manageQuests = "com.volcrypt.lootlist.manageQuests"
}

extension Notification.Name {
    static let quickActionTriggered = Notification.Name("quickActionTriggered")
}

@MainActor
final class QuickActionManager {
    static func updateQuickActions(for role: UserRole?) {
        guard let role else {
            UIApplication.shared.shortcutItems = []
            return
        }

        if role.isParent {
            UIApplication.shared.shortcutItems = [
                UIApplicationShortcutItem(
                    type: QuickActionType.processPayouts.rawValue,
                    localizedTitle: "Process Payouts",
                    localizedSubtitle: nil,
                    icon: UIApplicationShortcutIcon(systemImageName: "banknote"),
                    userInfo: nil
                ),
                UIApplicationShortcutItem(
                    type: QuickActionType.addQuickQuest.rawValue,
                    localizedTitle: "Add Quick Quest",
                    localizedSubtitle: nil,
                    icon: UIApplicationShortcutIcon(systemImageName: "plus.circle"),
                    userInfo: nil
                ),
                UIApplicationShortcutItem(
                    type: QuickActionType.addTemplate.rawValue,
                    localizedTitle: "Add Template",
                    localizedSubtitle: nil,
                    icon: UIApplicationShortcutIcon(systemImageName: "doc.badge.plus"),
                    userInfo: nil
                )
            ]
        } else {
            UIApplication.shared.shortcutItems = [
                UIApplicationShortcutItem(
                    type: QuickActionType.addTransaction.rawValue,
                    localizedTitle: "Add Transaction",
                    localizedSubtitle: nil,
                    icon: UIApplicationShortcutIcon(systemImageName: "banknote"),
                    userInfo: nil
                ),
                UIApplicationShortcutItem(
                    type: QuickActionType.manageQuests.rawValue,
                    localizedTitle: "Manage Quests",
                    localizedSubtitle: nil,
                    icon: UIApplicationShortcutIcon(systemImageName: "checkmark.seal"),
                    userInfo: nil
                )
            ]
        }
    }
}
