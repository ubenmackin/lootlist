//
//  LootListShortcuts.swift
//  LootList
//
//  Created by Ben Mackin on 8/6/26.
//

import AppIntents

struct LootListShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CompleteQuestIntent(),
            phrases: [
                "Complete a chore in \(.applicationName)",
                "Complete quest in \(.applicationName)",
                "Mark chore done in \(.applicationName)",
                "I cleaned my room in \(.applicationName)",
                "I finished a quest in \(.applicationName)"
            ],
            shortTitle: "Complete Chore",
            systemImageName: "checkmark.circle.fill"
        )

        AppShortcut(
            intent: LogSpendingIntent(),
            phrases: [
                "Log spending in \(.applicationName)",
                "Log transaction in \(.applicationName)",
                "Record spending in \(.applicationName)",
                "Log purchase in \(.applicationName)"
            ],
            shortTitle: "Log Spending",
            systemImageName: "banknote"
        )
    }
}
