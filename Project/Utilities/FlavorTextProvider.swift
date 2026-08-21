//
//  FlavorTextProvider.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import Foundation

enum FlavorTextProvider {
    /// Deprecated — use inline array in QuestCompletionEffectView
    static func questCompletion(rarity: QuestRarity) -> String {
        let options: [String] = switch rarity {
        case .common: ["Another task vanquished!", "The kingdom thanks you.", "Well done, adventurer."]
        case .rare: ["A worthy challenge, conquered!", "Your skills grow stronger."]
        case .epic: ["A legendary feat of bravery!", "Tales will be told of this deed!"]
        case .legendary: ["THE REALM TREMBLES AT YOUR POWER!", "You have achieved the impossible!"]
        }
        return options.randomElement() ?? options[0]
    }
}
