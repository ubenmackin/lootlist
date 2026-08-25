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

    /// A per-particle state record that the Canvas redraw loop animates.
    private struct Particle: Identifiable {
        let id: Int
        var positionX: CGFloat
        var positionY: CGFloat
        var rotation: Angle
        var color: Color
        var size: CGFloat
        var speed: CGFloat
        var drift: CGFloat
    }

    @State private var particles: [Particle] = []

    @State private var startTime: Date?

    private static let confettiColors: [Color] = [
        Color(DesignSystemConstants.Colors.primaryGreen),
        Color(DesignSystemConstants.Colors.accentBlue),
        Color(DesignSystemConstants.Colors.pendingAmber),
        Color(DesignSystemConstants.Colors.dangerRed),
        Color.purple,
        Color.pink,
        Color.teal,
        Color.orange
    ]

    var body: some View {
        if isPresented {
            TimelineView(.animation) { timeline in
                Canvas { context, size in
                    // Initialise particles on the first frame.
                    if startTime == nil {
                        startTime = timeline.date
                        particles = (0 ..< particleCount).map { particleIndex in
                            Particle(
                                id: particleIndex,
                                positionX: CGFloat.random(in: 0 ... size.width),
                                positionY: -CGFloat.random(in: 10 ... 60),
                                rotation: .degrees(Double.random(in: 0 ... 360)),
                                color: Self.confettiColors.randomElement() ?? .gold,
                                size: CGFloat.random(in: 6 ... 14),
                                speed: CGFloat.random(in: 1.0 ... 3.5),
                                drift: CGFloat.random(in: -1.0 ... 1.0)
                            )
                        }
                    }

                    let elapsed = timeline.date.timeIntervalSince(startTime ?? timeline.date)

                    for particleIndex in particles.indices {
                        var particle = particles[particleIndex]
                        particle.positionY += particle.speed * 1.5
                        particle.positionX += particle.drift * 0.8
                        particle.rotation += .degrees(particle.speed * 2.0)

                        // Wrap back to top so the stream looks continuous
                        // for the configured lifetime.
                        if particle.positionY > size.height + 20 {
                            particle.positionY = -CGFloat.random(in: 10 ... 40)
                            particle.positionX = CGFloat.random(in: 0 ... size.width)
                            particle.color = Self.confettiColors.randomElement() ?? .gold
                        }
                        particles[particleIndex] = particle

                        let rect = CGRect(
                            x: particle.positionX - particle.size / 2,
                            y: particle.positionY - particle.size / 2,
                            width: particle.size,
                            height: particle.size
                        )

                        var rotationContext = context
                        rotationContext.rotate(by: particle.rotation)

                        let isVertical = particleIndex % 3 == 0
                        let drawRect: CGRect = if isVertical {
                            CGRect(x: rect.midX - particle.size * 0.3,
                                   y: rect.minY,
                                   width: particle.size * 0.6,
                                   height: particle.size)
                        } else {
                            rect
                        }

                        rotationContext.fill(
                            Path(roundedRect: drawRect,
                                 cornerRadius: particle.size * 0.2),
                            with: .color(particle.color.opacity(smoothFade(elapsed)))
                        )
                    }
                }
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()
            .onAppear { startTime = nil }
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
