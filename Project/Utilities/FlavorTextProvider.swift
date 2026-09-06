//
//  FlavorTextProvider.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import Foundation

/// Encouraging celebration and reward copy for quest completions.
enum FlavorTextProvider {
    /// Single home for the complete-a-quest hint so checklist, hint card, help sheet, and detail tip never drift.
    static let questCompleteHint = "Complete a quest — tap ○ on a card!"
    static let questHintCardBody = "Tap the ○ on any quest card. If it says ‘Parent Verifies’ you’ll see ⏳ until they approve — otherwise you get your reward right away! Need more? Tap (?)"
    static let questHelpHowTo = "Tap the ○ on your quest card. For multi-part quests, tap Log # each time. You can also open the quest and tap Complete."

    static func questCompleteTip(rewardText: String) -> String {
        "Tip: tap Complete to earn \(rewardText). Parent-check quests show ⏳ until approved."
    }

    /// Locale-aware ordinal label ("1st", "2nd") for repeat counts.
    static func ordinal(_ value: Int) -> String {
        // WHY per-call formatter: NumberFormatter is not Sendable, so a thread-safe local keeps i18n without shared mutable state.
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        formatter.locale = .current
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// Legacy rarity tiers still size rewards internally, so parents need a way
    /// to pick one — but the old tier names never render; these plain effort
    /// labels stand in wherever a tier would have been shown.
    static func rewardTierName(for rarity: QuestRarity) -> String {
        switch rarity {
        case .common: "Quick Win"
        case .rare: "Extra Effort"
        case .epic: "Big Job"
        case .legendary: "Major Milestone"
        }
    }
}
