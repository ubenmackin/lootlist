//
//  QuestRarity.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation
import SwiftUI

public enum QuestRarity: String, CaseIterable, Identifiable, Codable, Sendable {
    case common = "Common"
    case rare = "Rare"
    case epic = "Epic"
    case legendary = "Legendary"

    public var id: String {
        rawValue
    }

    public var xpReward: Int {
        switch self {
        case .common: AppConstants.Rarity.commonXP
        case .rare: AppConstants.Rarity.rareXP
        case .epic: AppConstants.Rarity.epicXP
        case .legendary: AppConstants.Rarity.legendaryXP
        }
    }

    public var color: Color {
        // Rarity color tokens mapped from DesignSystemConstants.
        switch self {
        case .common: Color(DesignSystemConstants.Colors.rarityCommon)
        case .rare: Color(DesignSystemConstants.Colors.rarityRare)
        case .epic: Color(DesignSystemConstants.Colors.rarityEpic)
        case .legendary: Color(DesignSystemConstants.Colors.rarityLegendary)
        }
    }

    public var iconSystemName: String {
        switch self {
        case .common: "shield"
        case .rare: "sparkles"
        case .epic: "star.fill"
        case .legendary: "crown.fill"
        }
    }

    public static func from(xp: Int) -> QuestRarity {
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
