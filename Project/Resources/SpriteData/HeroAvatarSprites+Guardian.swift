//
//  HeroAvatarSprites+Guardian.swift
//  LootList
//
//  Created by Ben Mackin on 8/17/26.
//

import SwiftUI

extension HeroAvatarSprites {
    // MARK: - Guardian

    //
    // Grids are generated (see HeroAvatarSprites+GeneratedGrids.swift).

    static func guardianPalette(for preset: AvatarPreset) -> [Character: Color] {
        switch preset {
        case .guardianV1: // Ironclad Aegis — steel and gold
            heroPalette(
                hair: cCharcoal, hairShadow: color(hex: 0x0F0F17), hairLight: color(hex: 0x3A3A4C),
                skin: skinFair.base, skinShadow: skinFair.shadow, skinLight: cSkinFairHighlight,
                eye: cCyanGlow,
                outfit: cSteelMid, outfitDark: cIronBlack, outfitLight: cSteelLight,
                metal: cSteelLight, metalDark: cSteelDark, metalShine: cSteelHighlight,
                accent: cBrightGold
            )
        case .guardianV2: // Sentinel Titan — dark iron, tan skin
            heroPalette(
                hair: cCharcoal, hairShadow: color(hex: 0x0F0F17), hairLight: color(hex: 0x3A3A4C),
                skin: skinTan.base, skinShadow: skinTan.shadow, skinLight: cSkinTanHighlight,
                eye: cFlameOrange,
                outfit: cSteelDark, outfitDark: color(hex: 0x1F2937), outfitLight: color(hex: 0x8B93A5),
                metal: color(hex: 0x8B93A5), metalDark: cIronBlack, metalShine: cSteelMid,
                accent: cFlameOrange
            )
        case .guardianV3: // Defender Freya — silver and rose
            heroPalette(
                hair: cPinkRose, hairShadow: cDeepRose, hairLight: color(hex: 0xF78BC0),
                skin: skinFair.base, skinShadow: skinFair.shadow, skinLight: cSkinFairHighlight,
                eye: cRoyalBlue,
                outfit: cOffWhite, outfitDark: cSteelLight, outfitLight: cWhite,
                metal: cSteelHighlight, metalDark: cSteelMid, metalShine: cWhite,
                accent: cPinkRose
            )
        default: // Warden Briar — bronze and emerald
            heroPalette(
                hair: cForestGreen, hairShadow: color(hex: 0x14532D), hairLight: color(hex: 0x4ADE80),
                skin: skinDeep.base, skinShadow: skinDeep.shadow, skinLight: cSkinDeepHighlight,
                eye: cEmeraldGreen,
                outfit: cLeatherBrown, outfitDark: color(hex: 0x5C3608), outfitLight: color(hex: 0xC98A3D),
                metal: color(hex: 0xC98A3D), metalDark: color(hex: 0x7A4E1D), metalShine: color(hex: 0xEAB308),
                accent: cEmeraldGreen
            )
        }
    }
}
