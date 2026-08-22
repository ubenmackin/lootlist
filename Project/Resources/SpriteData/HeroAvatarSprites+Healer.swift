//
//  HeroAvatarSprites+Healer.swift
//  LootList
//
//  Created by Ben Mackin on 8/17/26.
//

import SwiftUI

extension HeroAvatarSprites {
    // MARK: - Healer

    //
    // Grids are generated (see HeroAvatarSprites+GeneratedGrids.swift).

    static func healerPalette(for preset: AvatarPreset) -> [Character: Color] {
        switch preset {
        case .healerV1: // High Priest Sol — white and gold, tan skin
            heroPalette(
                hair: cLeatherBrown, hairShadow: color(hex: 0x5C3608), hairLight: color(hex: 0x8B5E17),
                skin: skinTan.base, skinShadow: skinTan.shadow, skinLight: cSkinTanHighlight,
                eye: cBrightGold,
                outfit: cOffWhite, outfitDark: color(hex: 0xD4CFC0), outfitLight: cWhite,
                belt: cBrightGold,
                accent: cBrightGold
            )
        case .healerV2: // Monk Chen — sage robes, deep skin
            heroPalette(
                hair: cCharcoal, hairShadow: color(hex: 0x0F0F17), hairLight: color(hex: 0x3A3A4C),
                skin: skinDeep.base, skinShadow: skinDeep.shadow, skinLight: cSkinDeepHighlight,
                eye: cLeatherBrown,
                outfit: color(hex: 0xA3B18A), outfitDark: color(hex: 0x588157), outfitLight: color(hex: 0xCBDCC0),
                accent: cOffWhite
            )
        case .healerV3: // Cleric Lumina — white and rose, fair skin
            heroPalette(
                hair: cBrightGold, hairShadow: cFlameOrange, hairLight: cLightGold,
                skin: skinFair.base, skinShadow: skinFair.shadow, skinLight: cSkinFairHighlight,
                eye: cCyanGlow,
                outfit: cWhite, outfitDark: cSteelLight, outfitLight: cWhite,
                belt: cPinkRose,
                accent: cPinkRose
            )
        default: // Druid Willow — moss green, fair skin
            heroPalette(
                hair: cEmeraldGreen, hairShadow: cDarkGreen, hairLight: color(hex: 0x4ADE80),
                skin: skinFair.base, skinShadow: skinFair.shadow, skinLight: cSkinFairHighlight,
                eye: cForestGreen,
                outfit: color(hex: 0x84A98C), outfitDark: color(hex: 0x354F52), outfitLight: color(hex: 0xB8CDBF),
                accent: cLightGold
            )
        }
    }
}
