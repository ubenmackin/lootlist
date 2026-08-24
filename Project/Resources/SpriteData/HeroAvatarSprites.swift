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

    /// Bases are authored directly at 64x64 (generated losslessly from
    /// assets/blanks pixel art), so no upscaling or accessory stamping.
    private static func characterMatrix(for preset: AvatarPreset) -> [String] {
        HeroAvatarPixelBases.grid(for: preset)
    }

    private static func characterPalette(for preset: AvatarPreset) -> [Character: Color] {
        HeroAvatarPixelBases.palette(for: preset)
    }

    // MARK: - Equipment Layers

    static func backgroundEquipmentLayer(for gearKey: String) -> PixelLayer? {
        let key = normalizeGearKey(gearKey)
        // Specific matches must precede the generic "aura"/"wing" catches.
        if key.contains("lightning") || key.contains("bolt") || key.contains("level.10") {
            return lightningSparksBackgroundLayer()
        }
        if key.contains("rune") {
            return mysticRunesLayer()
        }
        if key.contains("starlight") || key.contains("star_aura") {
            return starAuraLayer()
        }
        if key.contains("royal_cape") {
            return royalCapeLayer()
        }
        if key.contains("frostweave") {
            return frostweaveLayer()
        }
        if key.contains("shadow_cloak") || key == "cloak" {
            return shadowCloakLayer()
        }
        if key.contains("phoenix") {
            return phoenixWingsLayer()
        }
        if key.contains("wing") {
            return goldenWingsLayer()
        }
        if key.contains("cosmic") || key.contains("aura") {
            return cosmicAuraBackgroundLayer()
        }
        return nil
    }

    static func foregroundEquipmentLayer(for gearKey: String) -> PixelLayer? {
        let key = normalizeGearKey(gearKey)
        // Ordered: earlier entries win. "bow" precedes "dragon", etc.
        let matchers: [([String], () -> PixelLayer)] = [
            (["crown"], crownLayer),
            (["bandana"], bandanaLayer),
            (["viking"], vikingHelmLayer),
            (["visor"], knightVisorLayer),
            (["wizard_hat", "wizard", "hat"], wizardHatLayer),
            (["mace"], holyMaceLayer),
            (["bow"], dragonBowLayer),
            (["dagger"], shadowDaggersLayer),
            (["staff"], crystalStaffLayer),
            (["flaming", "fire", "level.20"], flamingSwordLayer),
            (["glow_sprite"], glowSpriteLayer),
            (["griffin"], babyGriffinLayer),
            (["hatchling", "dragon"], dragonHatchlingLayer),
            (["familiar", "cat"], familiarCatLayer),
            (["sparkles", "level.5"], sparklesLayer),
            (["star"], starAuraLayer),
            (["cosmic", "aura"], cosmicAuraForegroundLayer)
        ]
        for (fragments, factory) in matchers where fragments.contains(where: key.contains) {
            return factory()
        }
        return nil
    }
}
