//
//  SpriteSnapshotRenderingTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/21/26.
//

import CoreGraphics
import Foundation
import ImageIO
@testable import LootList
import SwiftUI
import Testing
import UniformTypeIdentifiers

/// Renders sprite data to PNG files for design review.
/// Opt-in via `LOOTLIST_RENDER_SPRITES=1` so CI stays side-effect free:
///   LOOTLIST_RENDER_SPRITES=1 swift test --filter SpriteSnapshotRenderingTests
@MainActor
struct SpriteSnapshotRenderingTests {
    private var outputDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("sprite-previews", isDirectory: true)
    }

    @Test
    func `render sprites when opted in`() throws {
        guard ProcessInfo.processInfo.environment["LOOTLIST_RENDER_SPRITES"] == "1" else {
            return
        }

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        var renders: [(name: String, sprite: PixelSpriteData)] = []
        for preset in AvatarPreset.allCases {
            renders.append((name: preset.rawValue, sprite: HeroAvatarSprites.sprite(for: preset)))
        }

        let gearSets: [String: [String]] = [
            "gear_crown": ["crown"],
            "gear_wizard_hat": ["Wizard Hat"],
            "gear_flaming_sword": ["flaming_sword"],
            "gear_crystal_staff": ["crystal_staff"],
            "gear_golden_wings": ["golden_wings"],
            "gear_shadow_cloak": ["Shadow Cloak"],
            "gear_lightning": ["aura_lightning"],
            "gear_full_loadout": ["crown", "golden_wings", "cosmic_aura", "sparkles"]
        ]
        for (name, gear) in gearSets {
            renders.append((name: "knight_v1_\(name)", sprite: HeroAvatarSprites.sprite(for: .knightV1, equippedGear: gear)))
        }

        for render in renders {
            let image = try makeCGImage(from: render.sprite)
            let url = outputDirectory.appendingPathComponent("\(render.name).png") as CFURL
            guard let destination = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
                throw SpriteRenderError.failedToCreateImage
            }
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
        }
    }

    private func makeCGImage(from sprite: PixelSpriteData) throws -> CGImage {
        let width = sprite.width
        let height = sprite.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        var colorCache: [Color: RGBAComponents] = [:]

        func rgba(for color: Color) -> RGBAComponents {
            if let cached = colorCache[color] {
                return cached
            }
            let uiColor = UIColor(color)
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            let converted = RGBAComponents(
                red: UInt8(max(0, min(255, red * 255))),
                green: UInt8(max(0, min(255, green * 255))),
                blue: UInt8(max(0, min(255, blue * 255))),
                alpha: UInt8(max(0, min(255, alpha * 255)))
            )
            colorCache[color] = converted
            return converted
        }

        // Checkerboard background so transparency is visible during review.
        for rowIndex in 0 ..< height {
            for columnIndex in 0 ..< width {
                let index = (rowIndex * width + columnIndex) * 4
                let checker = (rowIndex / 4 + columnIndex / 4) % 2 == 0
                pixels[index] = checker ? 58 : 48
                pixels[index + 1] = checker ? 54 : 44
                pixels[index + 2] = checker ? 70 : 60
                pixels[index + 3] = 255
            }
        }

        for layer in sprite.layers.sorted(by: { $0.zIndex < $1.zIndex }) {
            for (rowIndex, row) in layer.matrix.enumerated() where rowIndex < height {
                for (columnIndex, char) in row.enumerated() where columnIndex < width {
                    guard let color = layer.palette[char], color != Color.clear else { continue }
                    let components = rgba(for: color)
                    let index = (rowIndex * width + columnIndex) * 4
                    pixels[index] = blend(foreground: components.red, background: pixels[index], alpha: components.alpha)
                    pixels[index + 1] = blend(foreground: components.green, background: pixels[index + 1], alpha: components.alpha)
                    pixels[index + 2] = blend(foreground: components.blue, background: pixels[index + 2], alpha: components.alpha)
                    pixels[index + 3] = 255
                }
            }
        }

        let image = pixels.withUnsafeMutableBytes { raw -> CGImage? in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return context.makeImage()
        }
        guard let image else {
            throw SpriteRenderError.failedToCreateImage
        }
        return image
    }

    private func blend(foreground: UInt8, background: UInt8, alpha: UInt8) -> UInt8 {
        let foregroundWeight = Double(foreground) * Double(alpha) / 255.0
        let backgroundWeight = Double(background) * (1.0 - Double(alpha) / 255.0)
        return UInt8(max(0, min(255, foregroundWeight + backgroundWeight)))
    }
}

private enum SpriteRenderError: Error {
    case failedToCreateImage
}

private struct RGBAComponents: Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8
}
