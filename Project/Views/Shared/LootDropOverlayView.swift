//
//  LootDropOverlayView.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import AudioToolbox
import SwiftUI

struct LootDropOverlayView: View {
    @Binding var isPresented: Bool
    let loot: LootDrop?

    @Environment(SoundManager.self) private var soundManager
    @AppStorage("celebrationSoundEnabled") private var celebrationSoundEnabled: Bool = true

    @State private var phase: AnimationPhase = .hidden
    @State private var chestRotation: Double = 0
    @State private var glowScale: CGFloat = 0.5
    @State private var glowOpacity: Double = 0.0

    enum AnimationPhase {
        case hidden
        case poppingIn
        case wobbling
        case opened
    }

    var body: some View {
        ZStack {
            if isPresented, let loot {
                Color.black.opacity(0.6)
                    .ignoresSafeArea()
                    .onTapGesture {
                        dismiss()
                    }

                contentCard(for: loot)
                    .padding(32)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Treasure Chest. \(phase == .opened ? "Opened. Loot: \(loot.gemAmount) gems, \(loot.description)" : "Opening...")")
                    .accessibilityAddTraits(.isModal)
                    .onAppear {
                        startAnimationSequence()
                    }
            }
        }
    }

    private func contentCard(for loot: LootDrop) -> some View {
        VStack(spacing: 24) {
            headerText(for: loot)
            chestAnimationArea(for: loot)
            actionButtonArea
        }
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.modal)
                .fill(Color(uiColor: .systemBackground))
                .shadow(radius: 20)
        )
    }

    @ViewBuilder
    private func headerText(for loot: LootDrop) -> some View {
        if phase == .opened {
            Text("\(loot.rarity.rawValue.uppercased()) TREASURE CHEST OPENED!")
                .font(.headline.weight(.bold))
                .foregroundStyle(loot.rarity.color)
                .multilineTextAlignment(.center)
                .transition(.opacity.combined(with: .scale))
                .accessibilityHidden(true)
        } else {
            Text("MYSTERIOUS TREASURE...")
                .font(.headline.weight(.bold))
                .foregroundStyle(.secondary)
                .opacity(phase == .hidden ? 0 : 1)
                .accessibilityHidden(true)
        }
    }

    private func chestAnimationArea(for loot: LootDrop) -> some View {
        ZStack {
            Circle()
                .fill(Color.gold.opacity(0.3))
                .frame(width: 150, height: 150)
                .scaleEffect(glowScale)
                .opacity(glowOpacity)

            if phase != .opened {
                Image(systemName: "archivebox.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120, height: 120)
                    .foregroundStyle(Color.gold, Color.orange.opacity(0.8))
                    .rotationEffect(.degrees(chestRotation))
                    .scaleEffect(phase == .hidden ? 0.001 : 1.0)
            }

            if phase == .opened {
                VStack(spacing: 8) {
                    Text("💎")
                        .font(.system(size: 64))

                    Text("+\(loot.gemAmount) Gems!")
                        .font(.title.bold())
                        .foregroundStyle(Color.gold)

                    Text(loot.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(height: 200)
    }

    @ViewBuilder
    private var actionButtonArea: some View {
        if phase == .opened {
            Button {
                dismiss()
            } label: {
                Text("Claim Loot")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.gold)
            .transition(.opacity.combined(with: .scale))
        } else {
            Button("Claim Loot") {}
                .buttonStyle(.borderedProminent)
                .opacity(0)
        }
    }

    private func startAnimationSequence() {
        phase = .hidden
        chestRotation = 0
        glowScale = 0.5
        glowOpacity = 0.0

        // 1. Pop in
        withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
            phase = .poppingIn
        }

        // 2. Wobble
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            phase = .wobbling
            withAnimation(.easeInOut(duration: 0.1).repeatCount(5, autoreverses: true)) {
                chestRotation = 15
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation {
                    chestRotation = 0
                }
            }
        }

        // 3. Open
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                phase = .opened
                glowScale = 2.5
                glowOpacity = 0.8
            }

            // Fade out glow slowly
            withAnimation(.easeOut(duration: 1.0).delay(0.2)) {
                glowOpacity = 0.0
            }

            if celebrationSoundEnabled {
                // If SoundManager doesn't expose a clean playSound method, use system sound as fallback
                AudioServicesPlaySystemSound(1322)
            }
            triggerHaptic()

            // Auto-dismiss after 4.5 seconds from opening
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
                if isPresented {
                    dismiss()
                }
            }
        }
    }

    private func dismiss() {
        withAnimation {
            isPresented = false
            phase = .hidden
        }
    }

    private func triggerHaptic() {
        if celebrationSoundEnabled {
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(.success)
        }
    }
}
