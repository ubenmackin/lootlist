//
//  PixelCanvasView.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import SwiftUI

// MARK: - Pixel Layer & Sprite Data Models

/// Represents an individual rendering layer of a pixel sprite.
struct PixelLayer: Sendable, Equatable, Identifiable {
    let id: String
    let matrix: [String]
    let palette: [Character: Color]
    let pixelOffset: CGPoint
    let opacity: Double
    let zIndex: Int

    init(
        id: String = UUID().uuidString,
        matrix: [String],
        palette: [Character: Color],
        pixelOffset: CGPoint = .zero,
        opacity: Double = 1.0,
        zIndex: Int = 0
    ) {
        self.id = id
        self.matrix = matrix
        self.palette = palette
        self.pixelOffset = pixelOffset
        self.opacity = opacity
        self.zIndex = zIndex
    }
}

/// Composite multi-layered pixel sprite specification.
struct PixelSpriteData: Sendable, Equatable {
    let width: Int
    let height: Int
    let layers: [PixelLayer]

    init(width: Int = 16, height: Int = 16, layers: [PixelLayer]) {
        self.width = width
        self.height = height
        self.layers = layers
    }

    init(matrix: [String], palette: [Character: Color], width: Int? = nil, height: Int? = nil) {
        let resolvedHeight = height ?? matrix.count
        let resolvedWidth = width ?? (matrix.first?.count ?? 16)
        self.width = resolvedWidth
        self.height = resolvedHeight
        self.layers = [
            PixelLayer(matrix: matrix, palette: palette)
        ]
    }
}

// MARK: - Pixel Canvas View

/// A SwiftUI Canvas view that renders pixel art matrices crisply with layer compositing and idle bobbing.
struct PixelCanvasView: View {
    let sprite: PixelSpriteData
    var animated: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBobbing: Bool = false

    init(sprite: PixelSpriteData, animated: Bool = true) {
        self.sprite = sprite
        self.animated = animated
    }

    init(matrix: [String], palette: [Character: Color], animated: Bool = true) {
        self.sprite = PixelSpriteData(matrix: matrix, palette: palette)
        self.animated = animated
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let spriteCols = max(1, sprite.width)
            let spriteRows = max(1, sprite.height)
            let pixelSize = min(size.width / CGFloat(spriteCols), size.height / CGFloat(spriteRows))
            let originX = (size.width - CGFloat(spriteCols) * pixelSize) / 2
            let originY = (size.height - CGFloat(spriteRows) * pixelSize) / 2

            Canvas { ctx, _ in
                guard size.width > 0, size.height > 0, pixelSize > 0 else { return }
                let sortedLayers = sprite.layers.sorted { $0.zIndex < $1.zIndex }

                for layer in sortedLayers {
                    let layerOpacity = layer.opacity
                    guard layerOpacity > 0 else { continue }

                    for (rowIndex, row) in layer.matrix.enumerated() {
                        guard rowIndex < spriteRows else { break }
                        for (colIndex, char) in row.enumerated() {
                            guard colIndex < spriteCols else { break }
                            guard let color = layer.palette[char], color != .clear else { continue }

                            let pixelX = originX + (CGFloat(colIndex) + layer.pixelOffset.x) * pixelSize
                            let pixelY = originY + (CGFloat(rowIndex) + layer.pixelOffset.y) * pixelSize

                            // Minimal overlap to eliminate subpixel gaps on retina displays
                            let rect = CGRect(
                                x: pixelX,
                                y: pixelY,
                                width: pixelSize + 0.05,
                                height: pixelSize + 0.05
                            )

                            if layerOpacity < 1.0 {
                                ctx.fill(Path(rect), with: .color(color.opacity(layerOpacity)))
                            } else {
                                ctx.fill(Path(rect), with: .color(color))
                            }
                        }
                    }
                }
            }
        }
        .offset(y: (animated && !reduceMotion && isBobbing) ? -1.5 : 0)
        .onAppear {
            if animated, !reduceMotion {
                withAnimation(
                    .easeInOut(duration: 1.2)
                        .repeatForever(autoreverses: true)
                ) {
                    isBobbing = true
                }
            }
        }
    }
}
