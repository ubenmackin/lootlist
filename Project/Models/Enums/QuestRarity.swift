import Foundation
import SwiftUI

enum QuestRarity: String, CaseIterable, Identifiable, Codable, Sendable {
    case common = "Common"
    case rare = "Rare"
    case epic = "Epic"
    case legendary = "Legendary"

    var id: String {
        rawValue
    }

    var xpReward: Int {
        switch self {
        case .common: AppConstants.Rarity.commonXP
        case .rare: AppConstants.Rarity.rareXP
        case .epic: AppConstants.Rarity.epicXP
        case .legendary: AppConstants.Rarity.legendaryXP
        }
    }

    var color: Color {
        switch self {
        case .common: Color.secondary
        case .rare: Color.blue
        case .epic: Color.purple
        case .legendary: Color.orange
        }
    }

    var iconSystemName: String {
        switch self {
        case .common: "shield"
        case .rare: "sparkles"
        case .epic: "star.fill"
        case .legendary: "crown.fill"
        }
    }

    static func from(xp: Int) -> QuestRarity {
        if xp >= AppConstants.Rarity.legendaryXP {
            return .legendary
        }
        if xp >= AppConstants.Rarity.epicXP {
            return .epic
        }
        if xp >= AppConstants.Rarity.rareXP {
            return .rare
        }
        return .common
    }
}
