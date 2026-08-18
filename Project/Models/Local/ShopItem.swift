//
//  ShopItem.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import Foundation
import SwiftUI

enum ShopCategory: String, CaseIterable, Sendable, Identifiable, Codable {
    case headwear
    case weapons
    case capes
    case auras
    case companions

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .headwear: "Headwear"
        case .weapons: "Weapons"
        case .capes: "Capes"
        case .auras: "Auras"
        case .companions: "Companions"
        }
    }

    var iconSystemName: String {
        switch self {
        case .headwear: "crown.fill"
        case .weapons: "shield.checkered"
        case .capes: "flag.fill"
        case .auras: "sparkles"
        case .companions: "pawprint.fill"
        }
    }
}

struct ShopItem: Identifiable, Sendable, Equatable, Hashable {
    let id: String
    let name: String
    let description: String
    let category: ShopCategory
    let gemPrice: Int
    let requiredLevel: Int
    let iconSystemName: String
    let layerKey: String
}

extension ShopItem {
    static let catalog: [ShopItem] = [
        // MARK: - Headwear

        ShopItem(
            id: "headwear_bandana",
            name: "Bandit Bandana",
            description: "A sleek rogue mask for stealthy adventurers.",
            category: .headwear,
            gemPrice: 30,
            requiredLevel: 1,
            iconSystemName: "theatermasks.fill",
            layerKey: "headwear_bandana"
        ),
        ShopItem(
            id: "headwear_viking_helm",
            name: "Viking Helm",
            description: "Sturdy horned helmet forged for fierce frontline warriors.",
            category: .headwear,
            gemPrice: 50,
            requiredLevel: 2,
            iconSystemName: "shield.checkered",
            layerKey: "headwear_viking_helm"
        ),
        ShopItem(
            id: "headwear_wizard_hat",
            name: "Wizard Hat",
            description: "A pointed sorcerer hat imbued with mystical arcane energy.",
            category: .headwear,
            gemPrice: 75,
            requiredLevel: 3,
            iconSystemName: "sparkles",
            layerKey: "headwear_wizard_hat"
        ),
        ShopItem(
            id: "headwear_knight_visor",
            name: "Knight Visor",
            description: "Polished steel helm with an adjustable protective visor.",
            category: .headwear,
            gemPrice: 90,
            requiredLevel: 4,
            iconSystemName: "shield.fill",
            layerKey: "headwear_knight_visor"
        ),
        ShopItem(
            id: "headwear_golden_crown",
            name: "Golden Crown",
            description: "A majestic crown forged of purest radiant gold.",
            category: .headwear,
            gemPrice: 120,
            requiredLevel: 5,
            iconSystemName: "crown.fill",
            layerKey: "headwear_crown"
        ),

        // MARK: - Weapons

        ShopItem(
            id: "weapon_shadow_daggers",
            name: "Shadow Daggers",
            description: "Twin daggers forged from solidified midnight shadows.",
            category: .weapons,
            gemPrice: 80,
            requiredLevel: 3,
            iconSystemName: "bolt.horizontal.fill",
            layerKey: "weapon_shadow_daggers"
        ),
        ShopItem(
            id: "weapon_astral_staff",
            name: "Astral Staff",
            description: "Channels celestial power from distant cosmic constellations.",
            category: .weapons,
            gemPrice: 100,
            requiredLevel: 4,
            iconSystemName: "wand.and.stars",
            layerKey: "weapon_astral_staff"
        ),
        ShopItem(
            id: "weapon_holy_mace",
            name: "Holy Mace",
            description: "A blessed warhammer radiating gentle divine warmth.",
            category: .weapons,
            gemPrice: 140,
            requiredLevel: 5,
            iconSystemName: "cross.fill",
            layerKey: "weapon_holy_mace"
        ),
        ShopItem(
            id: "weapon_flaming_sword",
            name: "Flaming Sword",
            description: "A radiant blade wreathed in eternal blazing dragonfire.",
            category: .weapons,
            gemPrice: 180,
            requiredLevel: 6,
            iconSystemName: "flame.fill",
            layerKey: "weapon_flaming_sword"
        ),
        ShopItem(
            id: "dragon_bow",
            name: "Dragon Bow",
            description: "Carved from dragon bone; shoots fiery piercing arrows.",
            category: .weapons,
            gemPrice: 220,
            requiredLevel: 8,
            iconSystemName: "arrow.up.right",
            layerKey: "weapon_dragon_bow"
        ),

        // MARK: - Capes

        ShopItem(
            id: "cape_royal_cape",
            name: "Royal Cape",
            description: "Crimson velvet cloak trimmed with golden royal embroidery.",
            category: .capes,
            gemPrice: 45,
            requiredLevel: 2,
            iconSystemName: "flag.fill",
            layerKey: "cape_royal_cape"
        ),
        ShopItem(
            id: "cape_shadow_cloak",
            name: "Shadow Cloak",
            description: "A flowing mantle that blends seamlessly into the darkness.",
            category: .capes,
            gemPrice: 95,
            requiredLevel: 4,
            iconSystemName: "moon.stars.fill",
            layerKey: "cape_shadow_cloak"
        ),
        ShopItem(
            id: "cape_frostweave",
            name: "Frostweave Cloak",
            description: "Woven from crystalline ice threads of high snowy peaks.",
            category: .capes,
            gemPrice: 190,
            requiredLevel: 7,
            iconSystemName: "snowflake",
            layerKey: "cape_frostweave"
        ),
        ShopItem(
            id: "cape_phoenix_wings",
            name: "Phoenix Wings",
            description: "Majestic feathered fiery wings leaving glowing embers.",
            category: .capes,
            gemPrice: 250,
            requiredLevel: 8,
            iconSystemName: "bird.fill",
            layerKey: "cape_phoenix_wings"
        ),

        // MARK: - Auras

        ShopItem(
            id: "aura_lightning",
            name: "Lightning Spark",
            description: "Crackling electric sparks dance playfully around footsteps.",
            category: .auras,
            gemPrice: 70,
            requiredLevel: 3,
            iconSystemName: "bolt.fill",
            layerKey: "aura_lightning"
        ),
        ShopItem(
            id: "aura_mystic_runes",
            name: "Mystic Runes",
            description: "Ancient arcane glyphs orbit peacefully around the hero.",
            category: .auras,
            gemPrice: 130,
            requiredLevel: 5,
            iconSystemName: "circle.hexagongrid.fill",
            layerKey: "aura_mystic_runes"
        ),
        ShopItem(
            id: "aura_cosmic",
            name: "Cosmic Aura",
            description: "Surrounds the hero with swirling nebulae and starshine.",
            category: .auras,
            gemPrice: 200,
            requiredLevel: 7,
            iconSystemName: "sun.max.fill",
            layerKey: "aura_cosmic"
        ),
        ShopItem(
            id: "aura_starlight",
            name: "Starlight Halo",
            description: "A dazzling crown of pure starshine illuminating the realm.",
            category: .auras,
            gemPrice: 280,
            requiredLevel: 9,
            iconSystemName: "star.fill",
            layerKey: "aura_starlight"
        ),

        // MARK: - Companions

        ShopItem(
            id: "companion_glow_sprite",
            name: "Glow Sprite",
            description: "A cheerful orb of warm starlight guiding your path.",
            category: .companions,
            gemPrice: 35,
            requiredLevel: 1,
            iconSystemName: "sparkle",
            layerKey: "companion_glow_sprite"
        ),
        ShopItem(
            id: "companion_familiar_cat",
            name: "Familiar Cat",
            description: "An intelligent mystical cat who purrs when quests finish.",
            category: .companions,
            gemPrice: 60,
            requiredLevel: 2,
            iconSystemName: "cat.fill",
            layerKey: "companion_familiar_cat"
        ),
        ShopItem(
            id: "companion_baby_griffin",
            name: "Baby Griffin",
            description: "A brave little griffin with tiny feathers and a big heart.",
            category: .companions,
            gemPrice: 175,
            requiredLevel: 6,
            iconSystemName: "pawprint.fill",
            layerKey: "companion_baby_griffin"
        ),
        ShopItem(
            id: "companion_dragon_hatchling",
            name: "Dragon Hatchling",
            description: "A friendly baby red dragon that breathes tiny harmless sparks.",
            category: .companions,
            gemPrice: 300,
            requiredLevel: 10,
            iconSystemName: "flame.circle.fill",
            layerKey: "companion_dragon_hatchling"
        )
    ]

    static func items(for category: ShopCategory) -> [ShopItem] {
        catalog.filter { $0.category == category }
    }

    static func item(withId id: String) -> ShopItem? {
        catalog.first { $0.id == id }
    }
}
