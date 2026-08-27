//
//  JourneyZoneDecorations.swift
//  LootList
//
//  Created by Ben Mackin on 8/22/26.
//

import SwiftUI

// MARK: - Zone Decoration Renderer

/// Renders panoramic landscape layers and natural landmark features across the Journey Map world.
/// Replaces hard-cut rectangular blocks with seamlessly blended horizons and organic biomes.
enum JourneyZoneDecorations {
    // MARK: - Continuous World Horizon Background

    /// Draws seamless multi-layered rolling terrain and horizons across the entire world width.
    static func continuousWorldBackground(totalWidth: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            // 1. Panoramic Sky
            Rectangle()
                .fill(JourneyZone.panoramicSkyGradient)
                .frame(width: totalWidth, height: height)

            // 2. Distant Horizon Mountain / Cloud Layer
            distantHorizonShape(width: totalWidth, height: height)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.18),
                            Color.white.opacity(0.04)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            // 3. Midground Rolling Terrain
            midgroundTerrainShape(width: totalWidth, height: height)
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: Color(red: 0.30, green: 0.58, blue: 0.25).opacity(0.7), location: 0.0),
                            .init(color: Color(red: 0.12, green: 0.30, blue: 0.18).opacity(0.7), location: 0.30),
                            .init(color: Color(red: 0.38, green: 0.40, blue: 0.45).opacity(0.7), location: 0.50),
                            .init(color: Color(red: 0.22, green: 0.08, blue: 0.06).opacity(0.7), location: 0.70),
                            .init(color: Color(red: 0.12, green: 0.05, blue: 0.22).opacity(0.7), location: 0.90)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )

            // 4. Foreground Main Ground Base
            foregroundGroundShape(width: totalWidth, height: height)
                .fill(JourneyZone.panoramicGroundGradient)

            // 5. Subtle Ground Shadow / Depth Gradient
            foregroundGroundShape(width: totalWidth, height: height)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.clear,
                            Color.black.opacity(0.35)
                        ],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                )
        }
        .frame(width: totalWidth, height: height)
    }

    // MARK: - Continuous Shapes

    private static func distantHorizonShape(width: CGFloat, height: CGFloat) -> Path {
        Path { path in
            path.move(to: CGPoint(x: 0, y: height))
            path.addLine(to: CGPoint(x: 0, y: height * 0.38))

            let segments = 24
            let segWidth = width / CGFloat(segments)
            for index in 0 ..< segments {
                let currentX = CGFloat(index) * segWidth
                let nextX = CGFloat(index + 1) * segWidth
                let midX = (currentX + nextX) / 2

                // Varying elevations across the world
                let worldProgress = currentX / width
                let elevationFactor: CGFloat = if worldProgress < 0.20 {
                    // Meadow: gentle low hills
                    0.40 + sin(Double(index) * 0.8) * 0.03
                } else if worldProgress < 0.40 {
                    // Forest: rolling tree line
                    0.36 + sin(Double(index) * 1.2) * 0.04
                } else if worldProgress < 0.60 {
                    // Mountains: towering crags
                    0.26 + sin(Double(index) * 1.6) * 0.08
                } else if worldProgress < 0.80 {
                    // Dragon's Reach: rugged volcanic peaks
                    0.30 + sin(Double(index) * 1.4) * 0.07
                } else {
                    // Eternal Realm: floating plateaus
                    0.34 + sin(Double(index) * 0.9) * 0.05
                }

                let yPos = height * elevationFactor
                path.addQuadCurve(
                    to: CGPoint(x: nextX, y: yPos),
                    control: CGPoint(x: midX, y: yPos - height * 0.02)
                )
            }

            path.addLine(to: CGPoint(x: width, y: height))
            path.closeSubpath()
        }
    }

    private static func midgroundTerrainShape(width: CGFloat, height: CGFloat) -> Path {
        Path { path in
            path.move(to: CGPoint(x: 0, y: height))
            path.addLine(to: CGPoint(x: 0, y: height * 0.48))

            let segments = 30
            let segWidth = width / CGFloat(segments)
            for index in 0 ..< segments {
                let currentX = CGFloat(index) * segWidth
                let nextX = CGFloat(index + 1) * segWidth
                let midX = (currentX + nextX) / 2

                let phase = Double(index) * 0.7
                let yOffset = sin(phase) * (height * 0.035)
                let yPos = height * 0.48 + yOffset

                path.addQuadCurve(
                    to: CGPoint(x: nextX, y: yPos),
                    control: CGPoint(x: midX, y: yPos - height * 0.02)
                )
            }

            path.addLine(to: CGPoint(x: width, y: height))
            path.closeSubpath()
        }
    }

    private static func foregroundGroundShape(width: CGFloat, height: CGFloat) -> Path {
        Path { path in
            path.move(to: CGPoint(x: 0, y: height))
            path.addLine(to: CGPoint(x: 0, y: height * 0.56))

            let segments = 20
            let segWidth = width / CGFloat(segments)
            for index in 0 ..< segments {
                let currentX = CGFloat(index) * segWidth
                let nextX = CGFloat(index + 1) * segWidth
                let midX = (currentX + nextX) / 2

                let phase = Double(index) * 0.5
                let yOffset = sin(phase) * (height * 0.025)
                let yPos = height * 0.56 + yOffset

                path.addQuadCurve(
                    to: CGPoint(x: nextX, y: yPos),
                    control: CGPoint(x: midX, y: yPos + height * 0.015)
                )
            }

            path.addLine(to: CGPoint(x: width, y: height))
            path.closeSubpath()
        }
    }

    // MARK: - Zone Specific Organic Features

    /// Renders localized landmark features for a zone centered at `zoneOffset` with width `zoneWidth`.
    @ViewBuilder
    static func zoneLandmarks(for zone: JourneyZone, zoneWidth: CGFloat, height: CGFloat) -> some View {
        switch zone {
        case .startingMeadow:
            meadowLandmarks(width: zoneWidth, height: height)
        case .denseForest:
            forestLandmarks(width: zoneWidth, height: height)
        case .mountainPass:
            mountainLandmarks(width: zoneWidth, height: height)
        case .dragonsReach:
            dragonsReachLandmarks(width: zoneWidth, height: height)
        case .eternalRealm:
            eternalRealmLandmarks(width: zoneWidth, height: height)
        }
    }

    // MARK: - Meadow Landmarks

    @ViewBuilder
    private static func meadowLandmarks(width: CGFloat, height: CGFloat) -> some View {
        // Glowing Sun in the upper sky
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        Color.gold.opacity(0.95),
                        Color.gold.opacity(0.45),
                        Color.clear
                    ],
                    center: .center,
                    startRadius: 10,
                    endRadius: 48
                )
            )
            .frame(width: 96, height: 96)
            .position(x: width * 0.72, y: height * 0.16)

        // Gentle clouds in sky
        cloudView(width: 70, height: 26, opacity: 0.35)
            .position(x: width * 0.28, y: height * 0.18)

        cloudView(width: 55, height: 20, opacity: 0.25)
            .position(x: width * 0.85, y: height * 0.24)

        // Wildflower clusters in the lower meadow
        flowerCluster(count: 8, seed: 101, width: width, height: height, color: Color.gold)
        flowerCluster(count: 6, seed: 202, width: width, height: height, color: Color(red: 1.0, green: 0.6, blue: 0.7))
        flowerCluster(count: 5, seed: 303, width: width, height: height, color: .white)
    }

    // MARK: - Forest Landmarks

    @ViewBuilder
    private static func forestLandmarks(width: CGFloat, height: CGFloat) -> some View {
        // Layered Pine Trees along the terrain
        ForEach(0 ..< 7, id: \.self) { index in
            let xPos = width * (0.08 + Double(index) * 0.13)
            let treeHeight = height * (0.09 + Double(index % 3) * 0.02)
            pineTree(height: treeHeight)
                .fill(Color(red: 0.08, green: 0.24, blue: 0.12).opacity(0.75))
                .frame(width: 26, height: treeHeight)
                .position(x: xPos, y: height * 0.44 + (index.isMultiple(of: 2) ? 6 : 0))
        }

        // Mystical Canopy Mist
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.clear,
                        Color(red: 0.4, green: 0.8, blue: 0.6).opacity(0.10),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: width, height: height * 0.25)
            .position(x: width * 0.5, y: height * 0.38)
    }

    // MARK: - Mountain Landmarks

    private static func mountainLandmarks(width: CGFloat, height: CGFloat) -> some View {
        // Jagged Snow-Capped Crags
        ForEach(0 ..< 4, id: \.self) { index in
            let xPos = width * (0.12 + Double(index) * 0.26)
            let peakH = height * (0.13 + Double(index % 2) * 0.04)
            mountainCrag(width: 70, height: peakH)
                .fill(Color(red: 0.38, green: 0.42, blue: 0.48).opacity(0.85))
                .frame(width: 70, height: peakH)
                .position(x: xPos, y: height * 0.40)

            // Snow cap
            snowCap(width: 24, height: peakH * 0.35)
                .fill(Color.white.opacity(0.75))
                .frame(width: 24, height: peakH * 0.35)
                .position(x: xPos, y: height * 0.40 - peakH * 0.35)
        }
    }

    // MARK: - Dragon's Reach Landmarks

    @ViewBuilder
    private static func dragonsReachLandmarks(width: CGFloat, height: CGFloat) -> some View {
        // Volcanic Spires
        ForEach(0 ..< 3, id: \.self) { index in
            let xPos = width * (0.2 + Double(index) * 0.3)
            let spireH = height * (0.14 + Double(index % 2) * 0.03)
            volcanicSpire(width: 65, height: spireH)
                .fill(Color(red: 0.18, green: 0.06, blue: 0.04).opacity(0.9))
                .frame(width: 65, height: spireH)
                .position(x: xPos, y: height * 0.42)
        }

        // Rising Embers
        ForEach(0 ..< 10, id: \.self) { index in
            let seeded = seededPosition(seed: 500 + index, width: width, height: height, yRange: 0.20 ... 0.65)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 1.0, green: 0.6, blue: 0.1).opacity(0.85),
                            Color(red: 0.9, green: 0.2, blue: 0.1).opacity(0.35),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 4
                    )
                )
                .frame(width: 8, height: 8)
                .position(x: seeded.x, y: seeded.y)
        }
    }

    // MARK: - Eternal Realm Landmarks

    @ViewBuilder
    private static func eternalRealmLandmarks(width: CGFloat, height: CGFloat) -> some View {
        // Star field across the cosmic sky
        ForEach(0 ..< 24, id: \.self) { index in
            let seeded = seededPosition(seed: 700 + index, width: width, height: height, yRange: 0.08 ... 0.50)
            let starSize = 2.0 + Double(index % 3) * 1.5
            Circle()
                .fill(Color.white.opacity(0.45 + Double(index % 4) * 0.15))
                .frame(width: starSize, height: starSize)
                .position(x: seeded.x, y: seeded.y)
        }

        // Floating Celestial Islands
        ForEach(0 ..< 3, id: \.self) { index in
            let xPos = width * (0.2 + Double(index) * 0.32)
            let yPos = height * (0.22 + Double(index % 2) * 0.08)
            floatingIslandShape()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.35, green: 0.22, blue: 0.55).opacity(0.8),
                            Color(red: 0.18, green: 0.08, blue: 0.35).opacity(0.8)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 54, height: 26)
                .position(x: xPos, y: yPos)
        }
    }

    // MARK: - Shapes

    private static func pineTree(height: CGFloat) -> Path {
        Path { path in
            let width: CGFloat = 26
            path.move(to: CGPoint(x: width / 2, y: 0))
            path.addLine(to: CGPoint(x: width, y: height * 0.80))
            path.addLine(to: CGPoint(x: 0, y: height * 0.80))
            path.closeSubpath()

            let trunkW = width * 0.22
            path.addRect(CGRect(
                x: (width - trunkW) / 2,
                y: height * 0.80,
                width: trunkW,
                height: height * 0.20
            ))
        }
    }

    private static func mountainCrag(width: CGFloat, height: CGFloat) -> Path {
        Path { path in
            path.move(to: CGPoint(x: width * 0.5, y: 0))
            path.addLine(to: CGPoint(x: width * 0.75, y: height * 0.4))
            path.addLine(to: CGPoint(x: width, y: height))
            path.addLine(to: CGPoint(x: 0, y: height))
            path.addLine(to: CGPoint(x: width * 0.25, y: height * 0.35))
            path.closeSubpath()
        }
    }

    private static func snowCap(width: CGFloat, height: CGFloat) -> Path {
        Path { path in
            path.move(to: CGPoint(x: width * 0.5, y: 0))
            path.addLine(to: CGPoint(x: width, y: height))
            path.addLine(to: CGPoint(x: width * 0.7, y: height * 0.75))
            path.addLine(to: CGPoint(x: width * 0.5, y: height * 0.9))
            path.addLine(to: CGPoint(x: width * 0.3, y: height * 0.75))
            path.addLine(to: CGPoint(x: 0, y: height))
            path.closeSubpath()
        }
    }

    private static func volcanicSpire(width: CGFloat, height: CGFloat) -> Path {
        Path { path in
            path.move(to: CGPoint(x: width * 0.45, y: 0))
            path.addLine(to: CGPoint(x: width * 0.55, y: 0))
            path.addLine(to: CGPoint(x: width, y: height))
            path.addLine(to: CGPoint(x: 0, y: height))
            path.closeSubpath()
        }
    }

    private static func floatingIslandShape() -> Path {
        Path { path in
            path.move(to: CGPoint(x: 6, y: 0))
            path.addLine(to: CGPoint(x: 48, y: 0))
            path.addQuadCurve(to: CGPoint(x: 54, y: 14), control: CGPoint(x: 56, y: 6))
            path.addQuadCurve(to: CGPoint(x: 0, y: 14), control: CGPoint(x: 27, y: 26))
            path.addQuadCurve(to: CGPoint(x: 6, y: 0), control: CGPoint(x: -2, y: 6))
            path.closeSubpath()
        }
    }

    private static func cloudView(width: CGFloat, height: CGFloat, opacity: Double) -> some View {
        ZStack {
            Capsule()
                .fill(Color.white.opacity(opacity))
                .frame(width: width, height: height * 0.65)
            Circle()
                .fill(Color.white.opacity(opacity))
                .frame(width: height * 0.85, height: height * 0.85)
                .offset(x: -width * 0.15, y: -height * 0.2)
            Circle()
                .fill(Color.white.opacity(opacity))
                .frame(width: height * 0.7, height: height * 0.7)
                .offset(x: width * 0.15, y: -height * 0.15)
        }
    }

    private static func flowerCluster(
        count: Int,
        seed: Int,
        width: CGFloat,
        height: CGFloat,
        color: Color
    ) -> some View {
        ForEach(0 ..< count, id: \.self) { index in
            let pos = seededPosition(seed: seed + index, width: width, height: height, yRange: 0.68 ... 0.92)
            Circle()
                .fill(color.opacity(0.55 + Double(index % 3) * 0.15))
                .frame(width: 5, height: 5)
                .position(x: pos.x, y: pos.y)
        }
    }

    private static func seededPosition(
        seed: Int,
        width: CGFloat,
        height: CGFloat,
        yRange: ClosedRange<Double>
    ) -> CGPoint {
        let xHash = Double((seed &* 2_654_435_761) & 0xFFFF) / 65535.0
        let yHash = Double(((seed &+ 17) &* 2_246_822_519) & 0xFFFF) / 65535.0
        let xPos = width * (0.05 + xHash * 0.90)
        let yPos = height * (yRange.lowerBound + yHash * (yRange.upperBound - yRange.lowerBound))
        return CGPoint(x: xPos, y: yPos)
    }
}
