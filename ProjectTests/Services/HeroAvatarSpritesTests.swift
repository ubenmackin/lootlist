//
//  HeroAvatarSpritesTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import Foundation
@testable import LootList
import SwiftUI
import Testing

@MainActor
struct HeroAvatarSpritesTests {
    @Test
    func `all 20 avatar presets produce valid canvas-sized pixel sprites`() {
        let allPresets = AvatarPreset.allCases
        #expect(allPresets.count == 20)

        for preset in allPresets {
            let spriteData = HeroAvatarSprites.sprite(for: preset)
            #expect(spriteData.width == HeroAvatarSprites.canvasSize)
            #expect(spriteData.height == HeroAvatarSprites.canvasSize)
            #expect(spriteData.layers.count == 1)

            let baseLayer = spriteData.layers[0]
            #expect(baseLayer.zIndex == 0)
            #expect(baseLayer.matrix.count == HeroAvatarSprites.canvasSize, "Preset \(preset) matrix should have \(HeroAvatarSprites.canvasSize) rows")

            for (rowIndex, row) in baseLayer.matrix.enumerated() {
                #expect(row.count == HeroAvatarSprites.canvasSize, "Preset \(preset) row \(rowIndex) should have \(HeroAvatarSprites.canvasSize) chars (got \(row.count))")

                for char in row {
                    #expect(baseLayer.palette[char] != nil, "Character '\(char)' missing in palette for preset \(preset)")
                }
            }
        }
    }

    @Test
    func `layer compositing with multiple equipped gear items`() {
        let gear = ["crown", "golden_wings", "flaming_sword", "cosmic_aura"]
        let spriteData = HeroAvatarSprites.sprite(for: .knightV1, equippedGear: gear)

        // Wings + Cosmic Aura BG (2 bg layers) + Base Layer + Crown + Sword + Cosmic Aura FG (3 fg layers) = 6 layers total
        #expect(spriteData.layers.count >= 4)

        let bgLayers = spriteData.layers.filter { $0.zIndex < 0 }
        let baseLayer = spriteData.layers.filter { $0.zIndex == 0 }
        let fgLayers = spriteData.layers.filter { $0.zIndex > 0 }

        #expect(!bgLayers.isEmpty, "Background gear (wings/aura) should have negative zIndex")
        #expect(baseLayer.count == 1, "Should have exactly 1 base character layer")
        #expect(!fgLayers.isEmpty, "Foreground gear (crown/sword) should have positive zIndex")

        // Check gear zIndex ordering
        let sorted = spriteData.layers.sorted { $0.zIndex < $1.zIndex }
        #expect(sorted.first?.zIndex ?? 0 < 0)
        #expect(sorted.last?.zIndex ?? 0 > 0)
    }

    @Test
    func `accessory gear variations and level gates`() {
        let level5Gear = HeroAvatarSprites.sprite(for: .mageV1, equippedGear: ["accessory.level.5"])
        #expect(level5Gear.layers.count == 2)
        #expect(level5Gear.layers.contains(where: { $0.id == "gear_sparkles" }))

        let wizardGear = HeroAvatarSprites.sprite(for: .mageV3, equippedGear: ["Wizard Hat", "Crystal Staff"])
        #expect(wizardGear.layers.count == 3)
        #expect(wizardGear.layers.contains(where: { $0.id == "gear_wizard_hat" }))
        #expect(wizardGear.layers.contains(where: { $0.id == "gear_crystal_staff" }))

        let shadowGear = HeroAvatarSprites.sprite(for: .rogueV1, equippedGear: ["Shadow Cloak"])
        #expect(shadowGear.layers.count == 2)
        #expect(shadowGear.layers.contains(where: { $0.id == "gear_shadow_cloak" }))
    }

    @Test
    func `pixel canvas view model initialization`() {
        let sampleMatrix = [
            "....yyyy....",
            "...yyyyyy...",
            "..yyyyyyyy..",
            "....yyyy...."
        ]
        let samplePalette: [Character: Color] = [
            ".": .clear,
            "y": .yellow
        ]

        let sprite = PixelSpriteData(matrix: sampleMatrix, palette: samplePalette)
        #expect(sprite.width == 12)
        #expect(sprite.height == 4)
        #expect(sprite.layers.count == 1)

        let canvasView = PixelCanvasView(sprite: sprite, animated: false)
        #expect(canvasView.sprite.width == 12)
        #expect(!canvasView.animated)
    }

    @Test
    func `all mascot companions produce valid canvas-sized pixel sprites`() {
        let companions = MascotCompanion.allCases
        let states: [MascotState] = [.idle, .inProgress, .encouraging, .celebrating, .bonusClaimed]

        for companion in companions {
            for state in states {
                for frameIndex in 0 ..< 2 {
                    let spriteData = MascotSpriteRenderer.sprite(for: companion, state: state, frameIndex: frameIndex)
                    #expect(
                        spriteData.width == MascotSpriteRenderer.canvasSize,
                        "Companion \(companion) state \(state) frame \(frameIndex) width should be \(MascotSpriteRenderer.canvasSize)"
                    )
                    #expect(
                        spriteData.height == MascotSpriteRenderer.canvasSize,
                        "Companion \(companion) state \(state) frame \(frameIndex) height should be \(MascotSpriteRenderer.canvasSize)"
                    )
                    #expect(spriteData.layers.count == 1, "Companion \(companion) state \(state) frame \(frameIndex) should have 1 layer")

                    let baseLayer = spriteData.layers[0]
                    #expect(baseLayer.zIndex == 0)
                    #expect(
                        baseLayer.matrix.count == MascotSpriteRenderer.canvasSize,
                        "Companion \(companion) state \(state) frame \(frameIndex) matrix should have \(MascotSpriteRenderer.canvasSize) rows"
                    )

                    for (rowIndex, row) in baseLayer.matrix.enumerated() {
                        #expect(
                            row.count == MascotSpriteRenderer.canvasSize,
                            "Companion \(companion) state \(state) frame \(frameIndex) row \(rowIndex) should have \(MascotSpriteRenderer.canvasSize) chars (got \(row.count))"
                        )

                        for char in row {
                            #expect(baseLayer.palette[char] != nil, "Character '\(char)' missing in palette for companion \(companion) state \(state) frame \(frameIndex)")
                        }
                    }
                }
            }
        }
    }
}
