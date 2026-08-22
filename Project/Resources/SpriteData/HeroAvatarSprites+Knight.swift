//
//  HeroAvatarSprites+Knight.swift
//  LootList
//
//  Created by Ben Mackin on 8/17/26.
//

import SwiftUI

extension HeroAvatarSprites {
    // MARK: - Knight

    //
    // Grids are generated (see HeroAvatarSprites+GeneratedGrids.swift).
    // This file owns the palette: change colors here, not in the grids.

    static func knightPalette(for preset: AvatarPreset) -> [Character: Color] {
        switch preset {
        case .knightV1: // Sir Valorous — blue tabard, fair skin, red plume
            heroPalette(
                hair: color(hex: 0xB45309), hairShadow: color(hex: 0x7C3A0D), hairLight: color(hex: 0xD98A2B),
                skin: skinFair.base, skinShadow: skinFair.shadow, skinLight: cSkinFairHighlight,
                eye: cEmeraldGreen,
                outfit: cRoyalBlue, outfitDark: cNavyBlue, outfitLight: color(hex: 0x5B8DEF),
                accent: cCrimsonRed
            )
        case .knightV2: // Sir Galahad — crimson tabard, tan skin, gold plume
            heroPalette(
                hair: color(hex: 0x4A2F16), hairShadow: color(hex: 0x2E1D0D), hairLight: color(hex: 0x6B4523),
                skin: skinTan.base, skinShadow: skinTan.shadow, skinLight: cSkinTanHighlight,
                eye: cRoyalBlue,
                outfit: cCrimsonRed, outfitDark: cDarkRed, outfitLight: color(hex: 0xF05A5A),
                accent: cBrightGold
            )
        case .knightV3: // Lady Clara — rose tabard, fair skin, gold plume
            heroPalette(
                hair: cFlameOrange, hairShadow: cLeatherBrown, hairLight: cBrightOrange,
                skin: skinFair.base, skinShadow: skinFair.shadow, skinLight: cSkinFairHighlight,
                eye: cEmeraldGreen,
                outfit: cPinkRose, outfitDark: cDeepRose, outfitLight: color(hex: 0xF78BC0),
                accent: cBrightGold
            )
        default: // Lady Joan — emerald tabard, deep skin, rose plume
            heroPalette(
                hair: cCharcoal, hairShadow: color(hex: 0x0F0F17), hairLight: color(hex: 0x3A3A4C),
                skin: skinDeep.base, skinShadow: skinDeep.shadow, skinLight: cSkinDeepHighlight,
                eye: cBrightGold,
                outfit: cEmeraldGreen, outfitDark: cDarkGreen, outfitLight: color(hex: 0x34D399),
                accent: cPinkRose
            )
        }
    }
}
