//
//  QuestCompletionEffectView.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import SwiftUI

struct QuestCompletionEffectView: View {
    let xpEarned: Int
    let goldEarned: Double?
    let rarity: QuestRarity
    @Binding var isShowing: Bool

    @Environment(SoundManager.self) private var soundManager

    @State private var textScale: CGFloat = 0.5
    @State private var textOpacity: Double = 0.0
    @State private var textFloatUp = false

    @State private var goldScale: CGFloat = 0.5
    @State private var goldOpacity: Double = 0.0
    @State private var goldFloatUp = false

    @State private var particlesActive = false
    @State private var flashVisible = false

    @State private var particles: [ParticleModel] = []
    @State private var flavorText: String = ""

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Flash overlay
                RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card)
                    .fill(rarity.color)
                    .opacity(flashVisible ? 0.2 : 0.0)

                // Particles
                ForEach(particles) { particle in
                    Circle()
                        .fill(particleColor)
                        .frame(width: particle.size, height: particle.size)
                        .scaleEffect(particlesActive ? 1.0 : 0.0)
                        .offset(x: particlesActive ? cos(particle.angle) * particle.distance : 0,
                                y: particlesActive ? sin(particle.angle) * particle.distance : 0)
                        .opacity(particlesActive ? 0.0 : 1.0)
                        .animation(.easeOut(duration: particle.duration), value: particlesActive)
                }
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)

                // Text
                ZStack {
                    VStack(spacing: 4) {
                        // Celebrates completion directly while immersive RPG layer is hidden.
                        Text("Quest Complete!")
                            .font(.headline.bold())
                            .foregroundColor(.white)

                        if !flavorText.isEmpty {
                            Text(flavorText)
                                .font(.caption.italic())
                                .foregroundColor(.white.opacity(0.9))
                        }
                    }
                    .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                    .scaleEffect(textScale)
                    .opacity(textOpacity)
                    .offset(y: textFloatUp ? -40 : 0)

                    if let amount = goldEarned {
                        Text("+" + CurrencyFormatter.string(amount))
                            .font(.subheadline.bold())
                            .foregroundColor(Color.gold)
                            .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                            .scaleEffect(goldScale)
                            .opacity(goldOpacity)
                            .offset(y: (goldFloatUp ? -40 : 0) + 30) // Positioned slightly below the XP text
                    }
                }
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: isShowing) { _, newValue in
            if newValue {
                startAnimation()
            }
        }
    }

    private var particleColor: Color {
        switch rarity {
        case .common: .gray
        case .rare: Color(DesignSystemConstants.Colors.accentBlue)
        case .epic: Color(DesignSystemConstants.Colors.accentBlue)
        case .legendary: Color.gold
        }
    }

    private func startAnimation() {
        guard isShowing else { return }

        // Play sound & haptic
        soundManager.play(.questComplete)

        // Setup flavor text — inlined (was FlavorTextProvider, single call site).
        // Plain-warm options; the rarity only sizes how big the moment feels.
        flavorText = {
            let options: [String] = switch rarity {
            case .common: ["Nice work — that's done!", "One more thing checked off.", "Well done!"]
            case .rare: ["That took real effort. Way to go!", "You're on a roll!"]
            case .epic: ["That was a big one — amazing!", "Something to be really proud of!"]
            case .legendary: ["Wow — you did it!", "What an accomplishment!"]
            }
            return options.randomElement() ?? options[0]
        }()

        // Generate particles
        let particleCount = switch rarity {
        case .common: 5
        case .rare: 7
        case .epic: 10
        case .legendary: 12
        }

        particles = (0 ..< particleCount).map { _ in
            ParticleModel(
                angle: Double.random(in: 0 ... (2 * .pi)),
                distance: CGFloat.random(in: 30 ... 60),
                size: CGFloat.random(in: 4 ... 8),
                duration: Double.random(in: 0.8 ... 1.2)
            )
        }

        // Reset states
        textScale = 0.5
        textOpacity = 0.0
        textFloatUp = false
        goldScale = 0.5
        goldOpacity = 0.0
        goldFloatUp = false
        particlesActive = false
        flashVisible = false

        Task {
            // Small delay to allow layout
            try? await Task.sleep(nanoseconds: 10_000_000)

            // 1. Flash
            flashVisible = true
            withAnimation(.easeOut(duration: 0.3)) {
                flashVisible = false
            }

            // 2. Burst particles
            particlesActive = true

            // 3. XP text pop
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                textScale = 1.2
                textOpacity = 1.0
            }

            // 4. Gold text pop (delayed by 0.2s)
            if goldEarned != nil {
                Task {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                        goldScale = 1.2
                        goldOpacity = 1.0
                    }

                    try? await Task.sleep(nanoseconds: 300_000_000)
                    withAnimation(.easeOut(duration: 1.2)) {
                        goldFloatUp = true
                        goldOpacity = 0.0
                    }
                }
            }

            // 5. XP text float
            try? await Task.sleep(nanoseconds: 300_000_000)
            withAnimation(.easeOut(duration: 1.2)) {
                textFloatUp = true
                textOpacity = 0.0
            }

            // 6. Finish
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            isShowing = false
        }
    }
}

private struct ParticleModel: Identifiable, Sendable {
    let id = UUID()
    let angle: Double
    let distance: CGFloat
    let size: CGFloat
    let duration: Double
}
