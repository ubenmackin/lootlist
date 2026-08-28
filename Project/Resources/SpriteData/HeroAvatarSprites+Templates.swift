//
//  HeroAvatarSprites+Templates.swift
//  LootList
//
//  Created by Ben Mackin on 8/21/26.
//

import SwiftUI

// MARK: - Compact Sprite Authoring Engine

// Sprites are authored as small native-resolution grids (one String per row, one Character per pixel)
// and upscaled 2x onto the 64x64 canvas with nearest-neighbor scaling.

extension HeroAvatarSprites {
    /// An overlay grid stamped onto a base grid at a native-resolution origin.
    struct SpriteOverlay: Sendable {
        let grid: [String]
        let offsetX: Int
        let offsetY: Int
    }

    /// Native authoring resolution.
    static let nativeWidth = 24
    static let nativeHeight = 30
    static let upscaleFactor = 2

    // MARK: Compositing

    /// Pastes overlay grids onto a base grid at native resolution.
    /// Overlay pixels equal to "." are treated as transparent.
    /// Rows are normalized (padded/truncated) to `nativeWidth`.
    static func composing(_ base: [String], overlays: [SpriteOverlay] = []) -> [String] {
        var canvas = base.map { Array(padRow($0)) }
        for overlay in overlays {
            for (rowOffset, row) in overlay.grid.enumerated() {
                let targetY = overlay.offsetY + rowOffset
                guard targetY >= 0, targetY < nativeHeight else { continue }
                for (colOffset, char) in row.enumerated() {
                    let targetX = overlay.offsetX + colOffset
                    guard targetX >= 0, targetX < nativeWidth, char != "." else { continue }
                    canvas[targetY][targetX] = char
                }
            }
        }
        return canvas.map { String($0) }
    }

    /// Upscales a native grid onto the full 64x64 canvas, horizontally centered,
    /// with the bottom row landing on row 60.
    static func upscaledToCanvas(_ grid: [String]) -> [String] {
        let normalized = grid.map { padRow($0) }
        let scaledWidth = nativeWidth * upscaleFactor
        let scaledHeight = nativeHeight * upscaleFactor
        let originX = (canvasSize - scaledWidth) / 2
        let originY = canvasSize - 3 - scaledHeight // feet at row 60

        var canvas: [String] = []
        for rowIndex in 0 ..< canvasSize {
            let sourceY = (rowIndex - originY) / upscaleFactor
            if rowIndex < originY || sourceY < 0 || sourceY >= normalized.count {
                canvas.append(String(repeating: ".", count: canvasSize))
                continue
            }
            let sourceRow = Array(normalized[sourceY])
            var rowChars = Array(repeating: Character("."), count: canvasSize)
            for columnIndex in 0 ..< scaledWidth {
                let sourceX = columnIndex / upscaleFactor
                guard sourceX < sourceRow.count else { continue }
                rowChars[originX + columnIndex] = sourceRow[sourceX]
            }
            canvas.append(String(rowChars))
        }
        return canvas
    }

    private static func padRow(_ row: String, width: Int = nativeWidth) -> String {
        if row.count > width {
            return String(row.prefix(width))
        }
        if row.count < width {
            return row + String(repeating: ".", count: width - row.count)
        }
        return row
    }

    // MARK: Shared Chibi Body

    /// Classic JRPG overworld chibi: big head (~45% of height), compact torso,
    /// stubby legs. Headwear/weapons are stamped on as overlays.
    static let chibiBodyGrid: [String] = [
        "......kkkkkkkkkkkk......", // 0  crown of hair
        "....kHHHHHHHHHHHHHHk....", // 1
        "...kHHHHHHHHHHHHHHHHk...", // 2
        "...kHHHHHHHHHHHHHHHHk...", // 3
        "...kHhhhhhhhhhhhhhhHk...", // 4  hair shadow band
        "...kHHHHHHHHHHHHHHHHk...", // 5
        "...kHHssssssssssssHHk...", // 6  fringe sides
        "...kHHssssssssssssHHk...", // 7
        "...kHHssseesseeesssHHk...", // 8  eyes
        "...kHHssseesseeesssHHk...", // 9
        "...kHHssssssssssssHHk...", // 10
        "...kssssssssssssssssk...", // 11 cheeks
        "....kSSSSSSSSSSSSSSk....", // 12 jaw shadow
        "......kssssssssssk......", // 13 neck
        "..kkbbbbbbbbbbbbbbbbkk..", // 14 shoulders
        ".kbbbbbbbbbbbbbbbbbbbbk.", // 15
        ".kaabbbbbbbbbbbbbbbbaak.", // 16 arms
        ".kaabbbbbbbbbbbbbbbbaak.", // 17
        ".kaabbbbbbbbbbbbbbbbaak.", // 18
        ".ktttttttttyytttttttttk.", // 19 belt + buckle
        ".kddddddddddddddddddddk.", // 20 hips
        ".kddddddddddddddddddddk.", // 21
        "..kddddddddkkddddddddk..", // 22 legs
        "..kddddddddkkddddddddk..", // 23
        "..kddddddddkkddddddddk..", // 24
        "..kddddddddkkddddddddk..", // 25
        "..kddddddddkkddddddddk..", // 26
        "..kddddddddkkddddddddk..", // 27
        "..kTTTTTTTTkkTTTTTTTTk..", // 28 boots
        "..kTTTTTTTTkkTTTTTTTTk.." // 29
    ]

    // MARK: Palettes

    /// Builds a palette honoring the structural character contract.
    static func heroPalette(
        hair: Color,
        hairShadow: Color,
        hairLight: Color? = nil,
        skin: Color,
        skinShadow: Color,
        skinLight: Color? = nil,
        eye: Color,
        outfit: Color,
        outfitDark: Color,
        outfitLight: Color? = nil,
        arm: Color? = nil,
        belt: Color = cLeatherBrown,
        boots: Color = cDarkWood,
        metal: Color = cSteelLight,
        metalDark: Color = cSteelDark,
        metalShine: Color = cSteelHighlight,
        trim: Color = cBrightGold,
        accent: Color = cCrimsonRed
    ) -> [Character: Color] {
        [
            ".": cClear,
            "k": cCharcoal,
            "H": hair,
            "h": hairShadow,
            "j": hairLight ?? hair,
            "s": skin,
            "S": skinShadow,
            "x": skinLight ?? skin,
            "e": eye,
            "w": cWhite,
            "b": outfit,
            "d": outfitDark,
            "c": outfitLight ?? outfit,
            "a": arm ?? outfit,
            "t": belt,
            "T": boots,
            "g": metal,
            "G": metalDark,
            "A": metalShine,
            "y": trim,
            "Y": cBrightGold,
            "q": accent
        ]
    }

    // MARK: Skin Tone Presets

    static let skinFair = (base: cSkinFair, shadow: cSkinFairShadow)
    static let skinTan = (base: cSkinTan, shadow: cSkinTanShadow)
    static let skinDeep = (base: cSkinDeep, shadow: cSkinDeepShadow)

    // MARK: Reusable Overlays

    /// Pointed cowl/hood with face opening. Colors come from the outfit
    /// characters, so rogue and healer reuse the same shape.
    static let cowlGrid: [String] = [
        ".........kk.........",
        "........kbdbk.......",
        "......kbbbdbbk......",
        ".....kbbbbbbdbk.....",
        "....kbssssssssbk....",
        "...kbssssssssssbk...",
        "...kbssssssssssbk...",
        "..kkkbssssssssbkkk.."
    ]

    /// Long hair side locks for female variants. Mirrored around the head.
    static func longHairOverlays() -> [SpriteOverlay] {
        [
            SpriteOverlay(grid: ["HH", "HH", "HH", "HH", "hH", "hh"], offsetX: 3, offsetY: 5),
            SpriteOverlay(grid: ["HH", "HH", "HH", "HH", "Hh", "hh"], offsetX: 19, offsetY: 5)
        ]
    }

    // MARK: Free-Floating Equipment Layers

    /// Stamps an authored grid directly onto a blank 64x64 layer canvas.
    /// Used for equipment overlays that float independently of the body.
    static func stampedLayer(
        id: String,
        grid: [String],
        palette: [Character: Color],
        zIndex: Int,
        originX: Int,
        originY: Int,
        scale: Int = 2,
        opacity: Double = 1.0
    ) -> PixelLayer {
        var canvas = Array(repeating: Array(repeating: Character("."), count: canvasSize), count: canvasSize)
        for (rowOffset, row) in grid.enumerated() {
            for (colOffset, char) in row.enumerated() where char != "." {
                for dy in 0 ..< scale {
                    for dx in 0 ..< scale {
                        let pixelX = originX + colOffset * scale + dx
                        let pixelY = originY + rowOffset * scale + dy
                        guard pixelX >= 0, pixelX < canvasSize, pixelY >= 0, pixelY < canvasSize else { continue }
                        canvas[pixelY][pixelX] = char
                    }
                }
            }
        }
        return PixelLayer(
            id: id,
            matrix: canvas.map { String($0) },
            palette: palette,
            opacity: opacity,
            zIndex: zIndex
        )
    }
}
