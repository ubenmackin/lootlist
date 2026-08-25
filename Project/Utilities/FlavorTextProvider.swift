//
//  FlavorTextProvider.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import Foundation

/// Celebration and reward wording for quest completions. This provider carries
/// the app's plain-warm voice: encouraging and specific about real progress,
/// with no leveling, XP, rarity, or currency jargon. The fantasy phrasing it
/// replaced stays recoverable behind `FeatureFlags.rpgImmersive`.
enum FlavorTextProvider {
    /// Deprecated — use inline array in QuestCompletionEffectView
    static func questCompletion(rarity: QuestRarity) -> String {
        // The rarity parameter only picks how big the moment feels; the words
        // themselves stay free of tier names so nothing RPG-flavored leaks out.
        let options: [String] = switch rarity {
        case .common: ["Nice work — that's done!", "One more thing checked off.", "Well done!"]
        case .rare: ["That took real effort. Way to go!", "You're on a roll!"]
        case .epic: ["That was a big one — amazing!", "Something to be really proud of!"]
        case .legendary: ["Wow — you did it!", "What an accomplishment!"]
        }
        return options.randomElement() ?? options[0]
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
