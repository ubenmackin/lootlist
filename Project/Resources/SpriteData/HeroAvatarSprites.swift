//
//  HeroAvatarSprites.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import SwiftUI

// MARK: - SPRITE AUTHORING SPEC (64x64)

// Canvas: 64x64, character 12–51 cols, 2–61 rows, feet at row 60.

enum HeroAvatarSprites: Sendable {
    // MARK: - Color Palette Helpers

    static func color(hex: UInt32, alpha: Double = 1.0) -> Color {
        let red = Double((hex >> 16) & 0xFF) / 255.0
        let green = Double((hex >> 8) & 0xFF) / 255.0
        let blue = Double(hex & 0xFF) / 255.0
        return Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    static let cClear = Color.clear
    static let cCharcoal = color(hex: 0x1E1E2E)
    static let cWhite = color(hex: 0xFFFFFF)
    static let cOffWhite = color(hex: 0xF8FAFC)
    static let cGold = Color.gold
    static let cBrightGold = color(hex: 0xFDE047)
    static let cLightGold = color(hex: 0xFEF08A)
    static let cGoldShadow = color(hex: 0xB45309)
    static let cSkinFairHighlight = color(hex: 0xFFE7D3)
    static let cSkinFair = color(hex: 0xFCD0B1)
    static let cSkinFairShadow = color(hex: 0xE8A588)
    static let cSkinTanHighlight = color(hex: 0xF4C98E)
    static let cSkinTan = color(hex: 0xE0AC69)
    static let cSkinTanShadow = color(hex: 0xC68642)
    static let cSkinDeepHighlight = color(hex: 0xA96B35)
    static let cSkinDeep = color(hex: 0x8D5524)
    static let cSkinDeepShadow = color(hex: 0x5C3818)
    static let cHairHighlight = color(hex: 0xFDE68A)
    static let cSteelHighlight = color(hex: 0xE2E8F0)
    static let cSteelLight = color(hex: 0xCBD5E1)
    static let cSteelMid = color(hex: 0x94A3B8)
    static let cSteelDark = color(hex: 0x475569)
    static let cIronBlack = color(hex: 0x1E293B)
    static let cRoyalBlue = color(hex: 0x2563EB)
    static let cNavyBlue = color(hex: 0x1E3A8A)
    static let cCyanGlow = color(hex: 0x06B6D4)
    static let cBrightCyan = color(hex: 0x22D3EE)
    static let cArcanePurple = color(hex: 0x7C3AED)
    static let cDeepPurple = color(hex: 0x4C1D95)
    static let cCrimsonRed = color(hex: 0xDC2626)
    static let cDarkRed = color(hex: 0x7F1D1D)
    static let cFlameOrange = color(hex: 0xEA580C)
    static let cBrightOrange = color(hex: 0xF97316)
    static let cEmeraldGreen = color(hex: 0x059669)
    static let cDarkGreen = color(hex: 0x064E3B)
    static let cForestGreen = color(hex: 0x15803D)
    static let cPinkRose = color(hex: 0xEC4899)
    static let cDeepRose = color(hex: 0xBE185D)
    static let cLeatherBrown = color(hex: 0x854D0E)
    static let cDarkWood = color(hex: 0x451A03)

    static let canvasSize: Int = 64

    static func sprite(for preset: AvatarPreset, equippedGear: [String] = []) -> PixelSpriteData {
        var layers: [PixelLayer] = []
        for gear in equippedGear {
            let key = normalizeGearKey(gear)
            if let bgLayer = backgroundEquipmentLayer(for: key) {
                layers.append(bgLayer)
            }
        }
        layers.append(baseCharacterLayer(for: preset))
        for gear in equippedGear {
            let key = normalizeGearKey(gear)
            if let fgLayer = foregroundEquipmentLayer(for: key) {
                layers.append(fgLayer)
            }
        }
        return PixelSpriteData(width: canvasSize, height: canvasSize, layers: layers)
    }

    private static func normalizeGearKey(_ raw: String) -> String {
        raw.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }

    // MARK: - Character Base Layer Dispatch

    static func baseCharacterLayer(for preset: AvatarPreset) -> PixelLayer {
        let matrix = characterMatrix(for: preset)
        let palette = characterPalette(for: preset)
        return PixelLayer(id: "base_\(preset.rawValue)", matrix: matrix, palette: palette, zIndex: 0)
    }

    private static func characterMatrix(for preset: AvatarPreset) -> [String] {
        // Female variants (v3/v4) use the female base silhouette; class
        // accessories are stamped on at native resolution, then upscaled.
        let female = preset.variationNumber >= 3
        let native = composing(
            female ? HeroAvatarTracedGrids.femaleBase : HeroAvatarTracedGrids.maleBase,
            overlays: accessoryOverlays(for: preset.avatarClass)
        )
        return upscaledToCanvas(native)
    }

    private static let tracedPalettes: [AvatarPreset: [Character: Color]] = [
        .knightV1: HeroAvatarTracedGrids.knightV1Palette,
        .knightV2: HeroAvatarTracedGrids.knightV2Palette,
        .knightV3: HeroAvatarTracedGrids.knightV3Palette,
        .knightV4: HeroAvatarTracedGrids.knightV4Palette,
        .mageV1: HeroAvatarTracedGrids.mageV1Palette,
        .mageV2: HeroAvatarTracedGrids.mageV2Palette,
        .mageV3: HeroAvatarTracedGrids.mageV3Palette,
        .mageV4: HeroAvatarTracedGrids.mageV4Palette,
        .rogueV1: HeroAvatarTracedGrids.rogueV1Palette,
        .rogueV2: HeroAvatarTracedGrids.rogueV2Palette,
        .rogueV3: HeroAvatarTracedGrids.rogueV3Palette,
        .rogueV4: HeroAvatarTracedGrids.rogueV4Palette,
        .guardianV1: HeroAvatarTracedGrids.guardianV1Palette,
        .guardianV2: HeroAvatarTracedGrids.guardianV2Palette,
        .guardianV3: HeroAvatarTracedGrids.guardianV3Palette,
        .guardianV4: HeroAvatarTracedGrids.guardianV4Palette,
        .healerV1: HeroAvatarTracedGrids.healerV1Palette,
        .healerV2: HeroAvatarTracedGrids.healerV2Palette,
        .healerV3: HeroAvatarTracedGrids.healerV3Palette,
        .healerV4: HeroAvatarTracedGrids.healerV4Palette
    ]

    private static func characterPalette(for preset: AvatarPreset) -> [Character: Color] {
        tracedPalettes[preset] ?? [:]
    }

    // MARK: - Equipment Layers

    static func backgroundEquipmentLayer(for gearKey: String) -> PixelLayer? {
        if gearKey.contains("wing") {
            return goldenWingsLayer()
        }
        if gearKey.contains("shadow_cloak") || gearKey == "cloak" {
            return shadowCloakLayer()
        }
        if gearKey.contains("aura") || gearKey.contains("cosmic") {
            return cosmicAuraBackgroundLayer()
        }
        if gearKey.contains("bolt") || gearKey.contains("level.10") {
            return lightningSparksBackgroundLayer()
        }
        return nil
    }

    static func foregroundEquipmentLayer(for gearKey: String) -> PixelLayer? {
        if gearKey.contains("crown") {
            return crownLayer()
        }
        if gearKey.contains("wizard_hat") || gearKey.contains("hat") {
            return wizardHatLayer()
        }
        if gearKey.contains("flaming_sword") || gearKey.contains("fire") || gearKey.contains("level.20") {
            return flamingSwordLayer()
        }
        if gearKey.contains("crystal_staff") || gearKey.contains("staff") {
            return crystalStaffLayer()
        }
        if gearKey.contains("sparkles") || gearKey.contains("level.5") {
            return sparklesLayer()
        }
        if gearKey.contains("star") || gearKey.contains("level.15") {
            return starAuraLayer()
        }
        if gearKey.contains("aura") || gearKey.contains("cosmic") {
            return cosmicAuraForegroundLayer()
        }
        return nil
    }
}
