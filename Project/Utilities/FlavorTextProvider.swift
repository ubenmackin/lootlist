//
//  FlavorTextProvider.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import Foundation

/// Encouraging celebration and reward copy for quest completions.
enum FlavorTextProvider {
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
