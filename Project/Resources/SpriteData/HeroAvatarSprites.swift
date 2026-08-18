//
//  HeroAvatarSprites.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import SwiftUI

// MARK: - SPRITE AUTHORING SPEC (64x64)

//
// Canvas: exactly 64 rows, each row EXACTLY 64 chars. Character occupies cols 12–51
// (max 40px wide) and rows 2–61 (max 60px tall); feet soles grounded at row 60;
// rows 61–63 empty except optional ground shadow row 61.
// Symmetry: front-facing, mirrored about col 32 (max 1px intentional asymmetry).
// Anatomy bands top→bottom: rows 2–8 headroom (hat/helm/plume/hood top); 8–16
// hair/helm crown; 16–22 forehead+brows; 18–21 EYES; 22–26 nose/cheeks; 24–27
// mouth; 26–30 chin/jaw; 30–34 neck+shoulders; 34–48 torso/chest; 48–52 belt/sash;
// 52–58 hips+upper legs; 58–61 lower legs+boots; row 60 boot soles.
// Eyes (SNES style, forward): 2px white sclera, 1px colored iris, 1px black pupil,
// 1px white glint top-left; eyes ~8 cols apart centered on col 32; female variants
// add lash/cheek shading, male variants add brows.
// Shading: every material = 3–4 tones (outline/shadow/base/highlight) with flat
// bands + 1px checkerboard dithering between bands (SNES style). NO smooth
// gradients. Silhouette outer edge = near-black outline (`k`).
// Palette discipline: every char in a matrix MUST have an entry in that layer's
// palette (tests assert this). Never invent a char without adding it to the layer's
// palette. Reuse existing key conventions per class.

// MARK: - Hero Avatar Sprites

enum HeroAvatarSprites: Sendable {
    // MARK: - Color Palette Helpers

    static func color(hex: UInt32, alpha: Double = 1.0) -> Color {
        let red = Double((hex >> 16) & 0xFF) / 255.0
        let green = Double((hex >> 8) & 0xFF) / 255.0
        let blue = Double(hex & 0xFF) / 255.0
        return Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    // Shared Palette Colors
    static let cClear = Color.clear
    static let cCharcoal = color(hex: 0x1E1E2E)
    static let cWhite = color(hex: 0xFFFFFF)
    static let cOffWhite = color(hex: 0xF8FAFC)
    static let cGold = Color.gold
    static let cBrightGold = color(hex: 0xFDE047)
    static let cLightGold = color(hex: 0xFEF08A)
    static let cGoldShadow = color(hex: 0xB45309)

    // Skin Tones
    static let cSkinFairHighlight = color(hex: 0xFFE7D3)
    static let cSkinFair = color(hex: 0xFCD0B1)
    static let cSkinFairShadow = color(hex: 0xE8A588)
    static let cSkinTanHighlight = color(hex: 0xF4C98E)
    static let cSkinTan = color(hex: 0xE0AC69)
    static let cSkinTanShadow = color(hex: 0xC68642)
    static let cSkinDeepHighlight = color(hex: 0xA96B35)
    static let cSkinDeep = color(hex: 0x8D5524)
    static let cSkinDeepShadow = color(hex: 0x5C3818)

    /// Hair
    static let cHairHighlight = color(hex: 0xFDE68A)

    // Metals & Greys
    static let cSteelHighlight = color(hex: 0xE2E8F0)
    static let cSteelLight = color(hex: 0xCBD5E1)
    static let cSteelMid = color(hex: 0x94A3B8)
    static let cSteelDark = color(hex: 0x475569)
    static let cIronBlack = color(hex: 0x1E293B)

    // Hues
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

    // MARK: - Sprite Provider

    /// Square canvas dimension shared by every hero avatar sprite (see spec above).
    static let canvasSize: Int = 64

    /// Generates a composite `PixelSpriteData` for a given character preset and equipped gear.
    static func sprite(for preset: AvatarPreset, equippedGear: [String] = []) -> PixelSpriteData {
        var layers: [PixelLayer] = []

        // 1. Background Aura / Wings layers (negative zIndex)
        for gear in equippedGear {
            let key = normalizeGearKey(gear)
            if let bgLayer = backgroundEquipmentLayer(for: key) {
                layers.append(bgLayer)
            }
        }

        // 2. Base Character layer (zIndex: 0)
        layers.append(baseCharacterLayer(for: preset))

        // 3. Foreground Accessories / Weapons / Headgear layers (positive zIndex)
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
}
