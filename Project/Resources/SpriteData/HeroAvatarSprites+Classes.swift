//
//  HeroAvatarSprites+Classes.swift
//  LootList
//
//  Character base-layer dispatch and per-class palette lookup.
//  Individual class matrices live in HeroAvatarSprites+{Knight,Mage,Rogue,Guardian,Healer}.swift.
//

import SwiftUI

extension HeroAvatarSprites {
    // MARK: - Character Base Layer Dispatch

    static func baseCharacterLayer(for preset: AvatarPreset) -> PixelLayer {
        let matrix = characterMatrix(for: preset)
        let palette = characterPalette(for: preset)
        return PixelLayer(id: "base_\(preset.rawValue)", matrix: matrix, palette: palette, zIndex: 0)
    }

    private static func characterMatrix(for preset: AvatarPreset) -> [String] {
        switch preset.avatarClass {
        case .knight: knightMatrix(for: preset)
        case .mage: mageMatrix(for: preset)
        case .rogue: rogueMatrix(for: preset)
        case .guardian: guardianMatrix(for: preset)
        case .healer: healerMatrix(for: preset)
        }
    }

    // MARK: - Character Palettes

    private static func characterPalette(for preset: AvatarPreset) -> [Character: Color] {
        var palette: [Character: Color] = [
            ".": cClear,
            "k": cCharcoal,
            "w": cWhite,
            "y": cGold,
            "Y": cBrightGold,
            "T": cDarkWood,
            "t": cLeatherBrown,
            "H": cHairHighlight,
            "W": cOffWhite,
            "u": cIronBlack
        ]

        switch preset.avatarClass {
        case .knight: populateKnightPalette(&palette, preset: preset)
        case .mage: populateMagePalette(&palette, preset: preset)
        case .rogue: populateRoguePalette(&palette, preset: preset)
        case .guardian: populateGuardianPalette(&palette, preset: preset)
        case .healer: populateHealerPalette(&palette, preset: preset)
        }

        return palette
    }

    private static func populateKnightPalette(_ palette: inout [Character: Color], preset: AvatarPreset) {
        switch preset {
        case .knightV1:
            palette["s"] = cSkinFair
            palette["S"] = cSkinFairShadow
            palette["A"] = cSteelHighlight
            palette["g"] = cSteelLight
            palette["G"] = cSteelDark
            palette["b"] = cRoyalBlue
            palette["B"] = cNavyBlue
            palette["c"] = cCyanGlow
            palette["I"] = cNavyBlue
        case .knightV2:
            palette["s"] = cSkinTan
            palette["S"] = cSkinTanShadow
            palette["A"] = cSteelHighlight
            palette["g"] = cSteelLight
            palette["G"] = cSteelDark
            palette["r"] = cCrimsonRed
            palette["R"] = cDarkRed
            palette["O"] = cFlameOrange
            palette["I"] = cDarkWood
        case .knightV3:
            palette["s"] = cSkinFair
            palette["S"] = cSkinFairShadow
            palette["h"] = cGold
            palette["H"] = cHairHighlight
            palette["u"] = cGoldShadow
            palette["A"] = cSteelHighlight
            palette["g"] = cSteelLight
            palette["G"] = cSteelDark
            palette["b"] = cRoyalBlue
            palette["B"] = cNavyBlue
            palette["c"] = cCyanGlow
            palette["I"] = cRoyalBlue
        case .knightV4:
            palette["s"] = cSkinFair
            palette["S"] = cSkinFairShadow
            palette["h"] = color(hex: 0x9A3412)
            palette["H"] = color(hex: 0xC05621)
            palette["u"] = cDarkRed
            palette["A"] = cSteelHighlight
            palette["g"] = cSteelLight
            palette["G"] = cSteelDark
            palette["r"] = cCrimsonRed
            palette["R"] = cDarkRed
            palette["O"] = cFlameOrange
            palette["I"] = cLeatherBrown
        default: break
        }
    }

    private static func populateMagePalette(_ palette: inout [Character: Color], preset: AvatarPreset) {
        switch preset {
        case .mageV1:
            palette["s"] = cSkinFair
            palette["S"] = cSkinFairShadow
            palette["p"] = cArcanePurple
            palette["P"] = cDeepPurple
            palette["r"] = cCrimsonRed
            palette["R"] = cDarkRed
            palette["o"] = cBrightOrange
            palette["O"] = cFlameOrange
            palette["T"] = cDarkWood
        case .mageV2:
            palette["s"] = cSkinFair
            palette["S"] = cSkinFairShadow
            palette["b"] = cRoyalBlue
            palette["B"] = cNavyBlue
            palette["c"] = cBrightCyan
            palette["y"] = cGold
            palette["Y"] = cBrightGold
            palette["T"] = cDarkWood
        case .mageV3:
            palette["s"] = cSkinFair
            palette["S"] = cSkinFairShadow
            palette["h"] = cArcanePurple
            palette["H"] = cHairHighlight
            palette["p"] = cArcanePurple
            palette["P"] = cDeepPurple
            palette["y"] = cGold
            palette["Y"] = cBrightGold
            palette["O"] = cFlameOrange
            palette["o"] = cBrightOrange
        case .mageV4:
            palette["s"] = cSkinFair
            palette["S"] = cSkinFairShadow
            palette["h"] = cFlameOrange
            palette["r"] = cCrimsonRed
            palette["R"] = cDarkRed
            palette["o"] = cBrightOrange
            palette["O"] = cFlameOrange
            palette["y"] = cGold
            palette["Y"] = cBrightGold
        default: break
        }
    }

    private static func populateRoguePalette(_ palette: inout [Character: Color], preset: AvatarPreset) {
        switch preset {
        case .rogueV1:
            palette["s"] = cSkinDeep
            palette["S"] = cDarkWood
            palette["U"] = cIronBlack
            palette["e"] = cEmeraldGreen
            palette["g"] = cSteelLight
        case .rogueV2:
            palette["s"] = cSkinTan
            palette["S"] = cSkinTanShadow
            palette["h"] = cLeatherBrown
            palette["e"] = cEmeraldGreen
            palette["E"] = cForestGreen
        case .rogueV3:
            palette["s"] = cSkinFair
            palette["S"] = cDeepPurple
            palette["p"] = cArcanePurple
            palette["P"] = cDeepPurple
            palette["c"] = cCyanGlow
            palette["C"] = cBrightCyan
        case .rogueV4:
            palette["s"] = cSkinTan
            palette["S"] = cDarkRed
            palette["K"] = cCharcoal
            palette["r"] = cCrimsonRed
            palette["R"] = cDarkRed
        default: break
        }
    }

    private static func populateGuardianPalette(_ palette: inout [Character: Color], preset: AvatarPreset) {
        switch preset {
        case .guardianV1:
            palette["s"] = cSkinFair
            palette["S"] = cSkinFairShadow
            palette["A"] = cSteelHighlight
            palette["g"] = cSteelLight
            palette["G"] = cSteelDark
            palette["u"] = cIronBlack
            palette["y"] = cGold
            palette["Y"] = cBrightGold
            palette["W"] = cOffWhite
            palette["I"] = cNavyBlue
            palette["b"] = cRoyalBlue
            palette["c"] = cCyanGlow
            palette["B"] = cNavyBlue
        case .guardianV2:
            palette["s"] = cSkinFair
            palette["S"] = cSkinFairShadow
            palette["b"] = cRoyalBlue
            palette["B"] = cNavyBlue
            palette["c"] = cCyanGlow
            palette["C"] = cBrightCyan
            palette["g"] = cSteelLight
            palette["G"] = cSteelDark
            palette["A"] = cSteelHighlight
            palette["u"] = cIronBlack
            palette["W"] = cOffWhite
            palette["y"] = cBrightGold
        case .guardianV3:
            palette["s"] = cSkinFair
            palette["S"] = cSkinFairShadow
            palette["h"] = cLightGold
            palette["H"] = cHairHighlight
            palette["y"] = cGold
            palette["Y"] = cBrightGold
            palette["c"] = cCyanGlow
            palette["C"] = cBrightCyan
            palette["g"] = cSteelLight
            palette["G"] = cSteelDark
            palette["u"] = cIronBlack
            palette["W"] = cOffWhite
        case .guardianV4:
            palette["s"] = cSkinTan
            palette["S"] = cSkinTanShadow
            palette["h"] = color(hex: 0x78350F)
            palette["H"] = cHairHighlight
            palette["y"] = cGold
            palette["Y"] = cBrightGold
            palette["c"] = cCyanGlow
            palette["C"] = cBrightCyan
            palette["e"] = cEmeraldGreen
            palette["E"] = cDarkGreen
            palette["u"] = cIronBlack
            palette["W"] = cOffWhite
        default: break
        }
    }

    private static func populateHealerPalette(_ palette: inout [Character: Color], preset: AvatarPreset) {
        switch preset {
        case .healerV1:
            palette["s"] = cSkinFair
            palette["S"] = cSkinFairShadow
            palette["h"] = cSteelLight
        case .healerV2:
            palette["s"] = cSkinTan
            palette["S"] = cSkinTanShadow
            palette["o"] = cFlameOrange
            palette["O"] = cFlameOrange
            palette["c"] = cCyanGlow
            palette["C"] = cBrightCyan
        case .healerV3:
            palette["s"] = cSkinFair
            palette["S"] = cSkinFairShadow
            palette["h"] = color(hex: 0xD97706)
            palette["m"] = cPinkRose
            palette["p"] = cPinkRose
            palette["P"] = color(hex: 0xF9A8D4)
        case .healerV4:
            palette["s"] = cSkinFair
            palette["S"] = cSkinFairShadow
            palette["h"] = color(hex: 0x16A34A)
            palette["e"] = cEmeraldGreen
            palette["E"] = cDarkGreen
            palette["m"] = cPinkRose
        default: break
        }
    }
}
