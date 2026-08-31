//
//  CelebrationOverlay.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import SwiftUI

/// Full-screen confetti burst driven by TimelineView + Canvas.
/// Auto-dismisses after the configured lifetime (default 5 s).
/// Used on quest completion, goal reached, and payout celebrations.
struct CelebrationOverlay: View {
    let isPresented: Bool

    var particleCount: Int = DesignSystemConstants.Celebration.confettiParticleCount

    var lifetime: TimeInterval = DesignSystemConstants.Celebration.confettiLifetime

    /// Deterministic particle specification derived from seed and index.
    private struct ParticleSpec: Sendable {
        let xFraction: Double
        let yOffset: Double
        let rotationDegrees: Double
        let colorIndex: Int
        let size: CGFloat
        let speed: CGFloat
        let drift: CGFloat
        let isVertical: Bool
    }

    @State private var startTime: Date = .now

    private static let confettiColors: [Color] = [
        Color(DesignSystemConstants.Colors.primaryGreen),
        Color(DesignSystemConstants.Colors.accentBlue),
        Color(DesignSystemConstants.Colors.pendingAmber),
        Color(DesignSystemConstants.Colors.dangerRed),
        .gold
    ]

    private static let precomputedSpecs: [ParticleSpec] = (0 ..< 100).map { particleIndex in
        func pseudoRandom(_ seed: Int) -> Double {
            let rawRandom = sin(Double(seed) * 127.1 + 311.7) * 43758.5453
            return rawRandom - floor(rawRandom)
        }
        let randomX = pseudoRandom(particleIndex * 7 + 1)
        let randomY = pseudoRandom(particleIndex * 7 + 2)
        let randomRot = pseudoRandom(particleIndex * 7 + 3)
        let randomColor = pseudoRandom(particleIndex * 7 + 4)
        let randomSize = pseudoRandom(particleIndex * 7 + 5)
        let randomSpeed = pseudoRandom(particleIndex * 7 + 6)

        return ParticleSpec(
            xFraction: randomX,
            yOffset: -10.0 - randomY * 50.0,
            rotationDegrees: randomRot * 360.0,
            colorIndex: Int(randomColor * 100),
            size: 6.0 + CGFloat(randomSize * 8.0),
            speed: 1.0 + CGFloat(randomSpeed * 2.5),
            drift: CGFloat(randomY * 2.0 - 1.0),
            isVertical: particleIndex % 3 == 0
        )
    }

    var body: some View {
        if isPresented {
            TimelineView(.animation) { timeline in
                Canvas { context, size in
                    guard size.width > 0, size.height > 0 else { return }
                    let elapsed = max(0, timeline.date.timeIntervalSince(startTime))
                    let count = min(particleCount, Self.precomputedSpecs.count)
                    let totalHeight = Double(size.height + 60.0)

                    for particleIndex in 0 ..< count {
                        let spec = Self.precomputedSpecs[particleIndex]

                        let fallSpeedPointsPerSec = Double(spec.speed) * 90.0
                        let totalFall = spec.yOffset + fallSpeedPointsPerSec * elapsed
                        let wrappedY = totalFall.truncatingRemainder(dividingBy: totalHeight)
                        let posY = CGFloat(wrappedY < 0 ? wrappedY + totalHeight - 40.0 : wrappedY - 40.0)

                        let totalDrift = Double(spec.drift * 48.0) * elapsed
                        let wobble = sin(elapsed * 2.5 + Double(spec.colorIndex)) * 8.0
                        let rawX = (spec.xFraction * Double(size.width)) + totalDrift + wobble
                        let wrappedX = rawX.truncatingRemainder(dividingBy: Double(size.width))
                        let posX = CGFloat(wrappedX < 0 ? wrappedX + Double(size.width) : wrappedX)

                        let rotation = Angle.degrees(spec.rotationDegrees + Double(spec.speed * 120.0) * elapsed)
                        let color = Self.confettiColors[spec.colorIndex % Self.confettiColors.count]

                        let rect = CGRect(
                            x: posX - spec.size / 2,
                            y: posY - spec.size / 2,
                            width: spec.size,
                            height: spec.size
                        )

                        var rotationContext = context
                        rotationContext.rotate(by: rotation)

                        let drawRect: CGRect = if spec.isVertical {
                            CGRect(
                                x: rect.midX - spec.size * 0.3,
                                y: rect.minY,
                                width: spec.size * 0.6,
                                height: spec.size
                            )
                        } else {
                            rect
                        }

                        rotationContext.fill(
                            Path(roundedRect: drawRect, cornerRadius: spec.size * 0.2),
                            with: .color(color.opacity(smoothFade(elapsed)))
                        )
                    }
                }
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()
            // UI tests assert the overlay's presence through this identifier;
            // hit-testing stays disabled so it never intercepts taps.
            .accessibilityIdentifier("celebration.overlay")
            .onAppear { startTime = .now }
            .onChange(of: isPresented) { _, presented in
                if presented {
                    startTime = .now
                }
            }
        }
    }

    /// Fade confetti opacity over the lifetime so particles dissolve
    /// rather than snapping off.
    private func smoothFade(_ elapsed: TimeInterval) -> Double {
        let fraction = min(elapsed / (lifetime * 0.85), 1.0)
        return 1.0 - fraction
    }

    // MARK: - AchievementService hook

    /// Centralized overlay hook for trophy unlocks — keeps AchievementService
    /// calls minimal and centralized for builder reconciliation.
    @MainActor
    static func show(achievement _: Achievement) {
        // No-op placeholder; concrete presentation is driven by CelebrationManager.
    }

    @MainActor
    static func show(item _: CelebrationItem) {
        // No-op placeholder; concrete presentation is driven by CelebrationManager.
    }
}
