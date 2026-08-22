//
//  HeroAvatarSprites+Mage.swift
//  LootList
//
//  Created by Ben Mackin on 8/17/26.
//

import SwiftUI

extension HeroAvatarSprites {
    // MARK: - Mage

    //
    // Grids are generated (see HeroAvatarSprites+GeneratedGrids.swift).

    static func magePalette(for preset: AvatarPreset) -> [Character: Color] {
        var palette: [Character: Color] = switch preset {
        case .mageV1: // Archmage Ignis — violet robes, tan skin
            heroPalette(
                hair: cCharcoal, hairShadow: color(hex: 0x0F0F17), hairLight: color(hex: 0x3A3A4C),
                skin: skinTan.base, skinShadow: skinTan.shadow, skinLight: cSkinTanHighlight,
                eye: cFlameOrange,
                outfit: cArcanePurple, outfitDark: cDeepPurple, outfitLight: color(hex: 0xA78BFA),
                accent: cBrightGold
            )
        case .mageV2: // Sorcerer Zephyr — navy robes, deep skin
            heroPalette(
                hair: cCharcoal, hairShadow: color(hex: 0x0F0F17), hairLight: color(hex: 0x3A3A4C),
                skin: skinDeep.base, skinShadow: skinDeep.shadow, skinLight: cSkinDeepHighlight,
                eye: cCyanGlow,
                outfit: cNavyBlue, outfitDark: color(hex: 0x15265E), outfitLight: color(hex: 0x5B8DEF),
                accent: cBrightGold
            )
        case .mageV3: // Enchantress Astra — cyan robes, fair skin
            heroPalette(
                hair: color(hex: 0x9B7BD4), hairShadow: color(hex: 0x6D53A3), hairLight: color(hex: 0xC4B0EE),
                skin: skinFair.base, skinShadow: skinFair.shadow, skinLight: cSkinFairHighlight,
                eye: cArcanePurple,
                outfit: cCyanGlow, outfitDark: color(hex: 0x087F94), outfitLight: cBrightCyan,
                accent: cBrightGold
            )
        default: // Pyromancer Ember — crimson robes, fair skin
            heroPalette(
                hair: cFlameOrange, hairShadow: cLeatherBrown, hairLight: cBrightOrange,
                skin: skinFair.base, skinShadow: skinFair.shadow, skinLight: cSkinFairHighlight,
                eye: cBrightOrange,
                outfit: cCrimsonRed, outfitDark: cDarkRed, outfitLight: color(hex: 0xF05A5A),
                accent: cFlameOrange
            )
        }
        // Wizard hat rides on dedicated characters.
        palette["v"] = palette["b"] ?? cArcanePurple
        palette["V"] = palette["d"] ?? cDeepPurple
        return palette
    }
}
