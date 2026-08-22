//
//  HeroAvatarSprites+Equipment.swift
//  LootList
//
//  Created by Ben Mackin on 8/17/26.
//

import SwiftUI

extension HeroAvatarSprites {
    // MARK: - Equipment Layers

    //
    // Each piece of gear is an authored compact grid stamped onto the 64x64
    // canvas. Background pieces use negative zIndex, foreground positive.

    // MARK: Crown (foreground)

    static func crownLayer() -> PixelLayer {
        stampedLayer(
            id: "gear_crown",
            grid: [
                "Y.Y.r.Y",
                "YYYYYYY",
                "yyyyyyy"
            ],
            palette: ["Y": cBrightGold, "y": cGold, "r": cCrimsonRed],
            zIndex: 25,
            originX: 25,
            originY: 2
        )
    }

    // MARK: Wizard Hat (foreground)

    static func wizardHatLayer() -> PixelLayer {
        stampedLayer(
            id: "gear_wizard_hat",
            grid: [
                "...........kk............",
                "..........kvvk...........",
                ".........kvvvvk..........",
                "........kvvvvvVk.........",
                ".......kvvvvvvvVk........",
                "......kvvvvvvvvvVk.......",
                ".....kqqqqqqqqqqqqqk.....",
                "...kVVvvvvvvvvvvvvvVVk...",
                ".kVVVVVVVVVVVVVVVVVVVVk..",
                "kVVVVVVVVVVVVVVVVVVVVVVk."
            ],
            palette: ["k": cCharcoal, "v": cDeepPurple, "V": cArcanePurple, "q": cBrightGold],
            zIndex: 25,
            originX: 6,
            originY: -4
        )
    }

    // MARK: Flaming Sword (foreground)

    static func flamingSwordLayer() -> PixelLayer {
        stampedLayer(
            id: "gear_flaming_sword",
            grid: [
                "..o...",
                ".oOo..",
                "oYOyo.",
                ".oOo..",
                ".Ag...",
                ".Ag...",
                ".Ag...",
                ".Ag...",
                ".Ag...",
                ".Ag...",
                ".Ag...",
                ".Ag...",
                ".Ag...",
                ".Ag...",
                ".Ag...",
                ".Ag...",
                ".Ag...",
                ".Ag...",
                "yyyy..",
                ".t....",
                ".t....",
                ".t....",
                ".y...."
            ],
            palette: [
                "o": cBrightOrange, "O": cFlameOrange, "Y": cBrightGold,
                "A": cSteelHighlight, "g": cSteelLight,
                "y": cBrightGold, "t": cLeatherBrown
            ],
            zIndex: 20,
            originX: 48,
            originY: 4
        )
    }

    // MARK: Crystal Staff (foreground)

    static func crystalStaffLayer() -> PixelLayer {
        stampedLayer(
            id: "gear_crystal_staff",
            grid: [
                "..C..",
                ".cCc.",
                "cCCCc",
                ".cCc.",
                "..C..",
                "..t..",
                "..t..",
                "..t..",
                "..t..",
                "..t..",
                "..t..",
                "..y..",
                "..t..",
                "..t..",
                "..t..",
                "..t..",
                "..t..",
                "..t..",
                "..t..",
                "..t..",
                "..t..",
                "..t.."
            ],
            palette: ["C": cBrightCyan, "c": cCyanGlow, "t": cDarkWood, "y": cBrightGold],
            zIndex: 20,
            originX: 4,
            originY: 4
        )
    }

    // MARK: Golden Wings (background)

    static func goldenWingsLayer() -> PixelLayer {
        let leftWing = [
            "..........YYyy",
            "........YYyyyy",
            "......YYyyyyyt",
            "....YYyyyyyttt",
            "..YYyyyyyyttt.",
            "Yyyyyyyyyttt..",
            "yyyyyyyytt....",
            ".yyyyyytt.....",
            "..yyyyt......."
        ]
        let grid = leftWing.map { $0 + ".." + String($0.reversed()) }
        return stampedLayer(
            id: "gear_golden_wings",
            grid: grid,
            palette: ["Y": cBrightGold, "y": cGold, "t": color(hex: 0xB45309)],
            zIndex: -10,
            originX: 1,
            originY: 12
        )
    }

    // MARK: Shadow Cloak (background)

    static func shadowCloakLayer() -> PixelLayer {
        var grid: [String] = []
        for rowIndex in 0 ..< 26 {
            let inset = max(0, 5 - rowIndex / 3)
            let width = 22 - inset * 2
            let padding = String(repeating: ".", count: inset)
            grid.append(padding + String(repeating: "d", count: width) + padding)
        }
        return stampedLayer(
            id: "gear_shadow_cloak",
            grid: grid,
            palette: ["d": color(hex: 0x1A1030)],
            zIndex: -5,
            originX: 10,
            originY: 8,
            opacity: 0.9
        )
    }

    // MARK: Cosmic Aura (background + foreground)

    static func cosmicAuraBackgroundLayer() -> PixelLayer {
        stampedLayer(
            id: "gear_cosmic_aura_bg",
            grid: [
                "....pppppppppppppp....",
                "..pp................pp",
                ".p....................p",
                "p......................p",
                "p......................p",
                ".p....................p",
                "..pp................pp.",
                "....pppppppppppppp...."
            ],
            palette: ["p": cArcanePurple],
            zIndex: -20,
            originX: 4,
            originY: 14,
            opacity: 0.45
        )
    }

    static func cosmicAuraForegroundLayer() -> PixelLayer {
        stampedLayer(
            id: "gear_cosmic_aura_fg",
            grid: [
                ".C...p......p...C.",
                "...p....CC....p...",
                ".p...C....C....p.."
            ],
            palette: ["p": cDeepPurple, "C": cBrightCyan],
            zIndex: 30,
            originX: 14,
            originY: 40,
            opacity: 0.6
        )
    }

    // MARK: Lightning Sparks (background)

    static func lightningSparksBackgroundLayer() -> PixelLayer {
        stampedLayer(
            id: "gear_lightning_sparks_bg",
            grid: [
                "..C.....",
                "..C.....",
                "..CCC...",
                "....C...",
                "....CC..",
                ".....C..",
                ".....C..",
                ".....CCC"
            ],
            palette: ["C": cBrightCyan],
            zIndex: -15,
            originX: 4,
            originY: 16,
            opacity: 0.85
        )
    }

    // MARK: Sparkles (foreground)

    static func sparklesLayer() -> PixelLayer {
        stampedLayer(
            id: "gear_sparkles",
            grid: [
                ".W...Y.....W....W",
                "WWW.WWW.W.WWW.WWW",
                ".W...Y.....W....W",
                ".....W...........",
                "..W.....W...Y....",
                ".WWW.Y.WWW.WWW...",
                "..W.....W...Y...."
            ],
            palette: ["W": cWhite, "Y": cBrightGold],
            zIndex: 35,
            originX: 16,
            originY: 2
        )
    }

    // MARK: Star Aura (foreground)

    static func starAuraLayer() -> PixelLayer {
        stampedLayer(
            id: "gear_star_aura",
            grid: [
                "Y...W...Y...W...Y...W...Y",
                "..........................",
                "..W...Y...W...Y...W...Y..",
                "..........................",
                "Y...W...Y...W...Y...W...Y"
            ],
            palette: ["Y": cBrightGold, "W": cOffWhite],
            zIndex: 35,
            originX: 4,
            originY: 2,
            opacity: 0.9
        )
    }
}
