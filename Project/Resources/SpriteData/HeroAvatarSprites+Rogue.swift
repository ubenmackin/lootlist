//
//  HeroAvatarSprites+Rogue.swift
//  LootList
//
//  Created by Ben Mackin on 8/17/26.
//

import SwiftUI

extension HeroAvatarSprites {
    // MARK: - Rogue

    //
    // Grids are generated (see HeroAvatarSprites+GeneratedGrids.swift).

    static func roguePalette(for preset: AvatarPreset) -> [Character: Color] {
        switch preset {
        case .rogueV1: // Shadowblade — charcoal leathers, fair skin
            heroPalette(
                hair: cCharcoal, hairShadow: color(hex: 0x0F0F17), hairLight: color(hex: 0x3A3A4C),
                skin: skinFair.base, skinShadow: skinFair.shadow, skinLight: cSkinFairHighlight,
                eye: cBrightGold,
                outfit: color(hex: 0x2E3440), outfitDark: color(hex: 0x1B202B), outfitLight: color(hex: 0x4C566A),
                belt: color(hex: 0x3E2723),
                accent: cEmeraldGreen
            )
        case .rogueV2: // Scout Fox — forest leathers, tan skin
            heroPalette(
                hair: color(hex: 0xB45309), hairShadow: color(hex: 0x7C3A0D), hairLight: color(hex: 0xD98A2B),
                skin: skinTan.base, skinShadow: skinTan.shadow, skinLight: cSkinTanHighlight,
                eye: cBrightGold,
                outfit: cForestGreen, outfitDark: color(hex: 0x14532D), outfitLight: color(hex: 0x4ADE80),
                belt: color(hex: 0x3E2723),
                accent: cFlameOrange
            )
        case .rogueV3: // Nightstalker — deep purple, fair skin
            heroPalette(
                hair: cArcanePurple, hairShadow: cDeepPurple, hairLight: color(hex: 0xA78BFA),
                skin: skinFair.base, skinShadow: skinFair.shadow, skinLight: cSkinFairHighlight,
                eye: cPinkRose,
                outfit: cDeepPurple, outfitDark: color(hex: 0x2E1065), outfitLight: color(hex: 0xA78BFA),
                belt: color(hex: 0x3E2723),
                accent: cCyanGlow
            )
        default: // Bandit Ruby — crimson leathers, deep skin
            heroPalette(
                hair: cCharcoal, hairShadow: color(hex: 0x0F0F17), hairLight: color(hex: 0x3A3A4C),
                skin: skinDeep.base, skinShadow: skinDeep.shadow, skinLight: cSkinDeepHighlight,
                eye: cBrightOrange,
                outfit: cDarkRed, outfitDark: color(hex: 0x541414), outfitLight: color(hex: 0xF05A5A),
                belt: color(hex: 0x3E2723),
                accent: cBrightGold
            )
        }
    }
}
