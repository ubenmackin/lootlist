//
//  CelebrationOverlayView.swift
//  LootList
//
//  Created by Ben Mackin on 8/10/26.
//

import AudioToolbox
import SwiftUI
import UIKit

/// Fullscreen celebration overlay shown by ``CelebrationManager`` when a
/// trophy is unlocked or a streak milestone is reached. Renders a darkened
/// blurred backdrop, a spring-animated badge, the trophy name and description,
/// a confetti particle effect, and an optional "View Trophies" action. The
/// overlay auto-dismisses after 6 seconds (timer owned by
/// ``CelebrationManager``); tapping anywhere skips immediately. A chime
/// (system sound 1322) and success haptic fire on appear, gated by the
/// `celebrationSoundEnabled` user preference.
struct CelebrationOverlayView: View {
    let item: CelebrationItem
    let familyRecordName: String?
    let onDismiss: () -> Void

    @State private var appeared = false
    @State private var presentTrophyRoom = false

    /// Mirrors the toggle surfaced in `NotificationSettingsView`. Defaults to
    /// `true` so a fresh install celebrates audibly until the user opts out.
    @AppStorage("celebrationSoundEnabled") private var soundEnabled = true

    /// Reused across celebrations per Apple's guidance (a single generator
    /// should be held for coordinated feedback). Held on the view so the same
    /// instance fires on every appearance rather than being recreated per
    /// trigger, and so `.prepare()` can be called ahead of the fire.
    private let hapticGenerator = UINotificationFeedbackGenerator()

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.65))
                .background(.ultraThinMaterial)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            ConfettiView()
                .allowsHitTesting(false)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                badge

                if item.isLevelUp {
                    LevelUpDetailsView(item: item)
                } else {
                    VStack(spacing: 8) {
                        Text(item.isStreakMilestone ? "🔥 Streak Milestone!" : "🏆 Trophy Unlocked!")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.gold)
                            .textCase(.uppercase)
                            .accessibilityHidden(true)

                        Text(item.name)
                            .font(.title.bold())
                            .multilineTextAlignment(.center)

                        Text(item.description)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }

                Button {
                    onDismiss()
                    presentTrophyRoom = true
                } label: {
                    Label("View Trophies", systemImage: "trophy.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(28)
            .scaleEffect(appeared ? 1.0 : DesignSystemConstants.Celebration.initialScale)
            .opacity(appeared ? 1 : 0)
            .animation(.spring(response: 0.5, dampingFraction: 0.6), value: appeared)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(item.isStreakMilestone ? "Streak milestone" : "Trophy unlocked"): \(item.name)")
            .accessibilityValue(item.description)
            .accessibilityHint("Double tap anywhere to dismiss")
        }
        .onAppear {
            playChime()
            triggerHaptic()
            withAnimation { appeared = true }
        }
        .sheet(isPresented: $presentTrophyRoom) {
            NavigationStack {
                TrophyRoomView(familyRecordName: familyRecordName)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { presentTrophyRoom = false }
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var badge: some View {
        if item.isLevelUp {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [.blue.opacity(0.4), .purple.opacity(0.2)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 110, height: 110)

                Circle()
                    .strokeBorder(Color.blue.opacity(0.5), lineWidth: 2)
                    .frame(width: 110, height: 110)

                Text("\(item.newLevel ?? 2)")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(Color.blue)
            }
            .accessibilityHidden(true)
        } else {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.gold.opacity(0.4), Color.orange.opacity(0.2)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 110, height: 110)

                Circle()
                    .strokeBorder(Color.gold.opacity(0.5), lineWidth: 2)
                    .frame(width: 110, height: 110)

                Image(systemName: item.iconSystemName)
                    .font(.system(size: 48))
                    .foregroundStyle(Color.gold)
            }
            .accessibilityHidden(true)
        }
    }

    private func playChime() {
        guard soundEnabled else { return }
        AudioServicesPlaySystemSound(1322)
    }

    private func triggerHaptic() {
        guard soundEnabled else { return }
        hapticGenerator.prepare()
        hapticGenerator.notificationOccurred(.success)
    }
}

private struct LevelUpDetailsView: View {
    let item: CelebrationItem
    @State private var displayLevel: Int

    init(item: CelebrationItem) {
        self.item = item
        self._displayLevel = State(initialValue: item.oldLevel ?? 1)
    }

    var body: some View {
        VStack(spacing: 8) {
            Text("⬆️ Level Up!")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.blue)
                .textCase(.uppercase)
                .accessibilityHidden(true)

            HStack(spacing: 8) {
                Text("Level \(item.oldLevel ?? 1)")
                    .font(.title.bold())
                    .foregroundStyle(.secondary)

                Image(systemName: "arrow.right")
                    .font(.title2.bold())

                Text("Level \(displayLevel)")
                    .font(.title.bold())
                    .contentTransition(.numericText())
            }

            if let newTitle = item.newTitle {
                Text("You are now a \(newTitle)!")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.6).delay(0.5)) {
                displayLevel = item.newLevel ?? 2
            }
        }
    }
}

// MARK: - Confetti

/// Canvas + TimelineView confetti particle system. Particles are derived
/// deterministically from their index (no RNG state), so the burst is stable
/// across re-renders. Each particle falls under gravity with a sinusoidal
/// horizontal wobble and rotates, fading out near the end of its lifetime.
private struct ConfettiView: View {
    @State private var start: Date?

    private static let particleCount = DesignSystemConstants.Celebration.confettiParticleCount
    private static let lifetime: TimeInterval = DesignSystemConstants.Celebration.confettiLifetime
    private static let palette: [Color] = [
        .red, .orange, .yellow, .green, .blue, .purple, .pink, .teal
    ]

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                guard let start else { return }
                let elapsed = timeline.date.timeIntervalSince(start)
                guard elapsed >= 0 else { return }

                for index in 0 ..< Self.particleCount {
                    let particle = Self.particle(index: index)
                    let localT = max(0, elapsed - particle.delay)
                    guard localT <= Self.lifetime else { continue }

                    let progress = localT / Self.lifetime
                    let posY = -20 + progress * (size.height + 60)
                    let wobble = sin((localT + particle.delay) * 3.0) * 30
                    let posX = size.width * particle.xRatio + wobble + particle.drift * progress
                    let opacity = progress < 0.8
                        ? 1.0
                        : max(0, 1 - (progress - 0.8) / 0.2)
                    let rotation = localT * particle.angularVelocity

                    var local = ctx
                    local.translateBy(x: posX, y: posY)
                    local.rotate(by: .degrees(rotation))
                    let rect = CGRect(x: -5, y: -8, width: 10, height: 16)
                    local.fill(
                        Path(rect),
                        with: .color(particle.color.opacity(opacity))
                    )
                }
            }
        }
        .onAppear { start = Date() }
    }

    /// Deterministic particle descriptor for a given index.
    private static func particle(index: Int) -> Particle {
        let color = palette[index % palette.count]
        let xRatio = Double(index) / Double(particleCount)
        let delay = Double(index % 10) * 0.05
        let angularVelocity = Double((index % 5) + 1) * 60.0
        let drift = Double((index % 7) - 3) * 20.0
        return Particle(
            color: color,
            xRatio: xRatio,
            delay: delay,
            angularVelocity: angularVelocity,
            drift: drift
        )
    }

    private struct Particle: Sendable {
        let color: Color
        let xRatio: Double
        let delay: Double
        let angularVelocity: Double
        let drift: Double
    }
}
