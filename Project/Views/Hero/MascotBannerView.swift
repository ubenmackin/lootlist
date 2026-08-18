//
//  MascotBannerView.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import SwiftUI

struct MascotBannerView: View {
    @Environment(BonusObjectiveService.self) private var bonusService
    @Environment(GemService.self) private var gemService
    @Environment(SoundManager.self) private var soundManager

    let profile: Profile
    let quests: [QuestCache]
    let completions: [QuestCompletionCache]
    let showBonusCard: Bool

    init(
        profile: Profile,
        quests: [QuestCache],
        completions: [QuestCompletionCache],
        showBonusCard: Bool = true
    ) {
        self.profile = profile
        self.quests = quests
        self.completions = completions
        self.showBonusCard = showBonusCard
    }

    @State private var frameIndex: Int = 0
    @State private var isClaiming: Bool = false
    @State private var showConfetti: Bool = false

    var body: some View {
        let companion = MascotCompanion(rawValue: profile.mascotCompanion ?? "cat") ?? .cat
        let state = currentMascotState()
        let objective = bonusService.dailyObjective(for: profile)
        let isClaimed = bonusService.isClaimed(objective: objective, profile: profile)
        let eval = bonusService.evaluateProgress(objective: objective, todayQuests: quests, completions: completions)

        HStack(alignment: .top, spacing: 16) {
            // Mascot Sprite
            VStack {
                mascotSprite(companion: companion, state: isClaimed ? .bonusClaimed : state)
                    .frame(width: 64, height: 64)
                    .offset(y: frameIndex == 0 ? 0 : -4)
                    .animation(.easeInOut(duration: 0.5), value: frameIndex)
            }
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 12) {
                // Speech Bubble
                VStack(alignment: .leading, spacing: 4) {
                    Text(companion.name)
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(companion.themeColor)

                    Text(companion.dialogue(state: isClaimed ? .bonusClaimed : state, objective: objective))
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(DesignSystemConstants.CornerRadius.small)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small)
                        .stroke(companion.themeColor.opacity(0.3), lineWidth: 1)
                )

                if showBonusCard {
                    // Bonus Objective Card
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "star.circle.fill")
                                .foregroundStyle(Color.gold)
                            Text("Daily Bonus")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundStyle(.secondary)
                        }

                        Text(objective.title)
                            .font(.subheadline)
                            .fontWeight(.semibold)

                        Text(objective.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
                            Text(eval.progressText)
                                .font(.caption2)
                                .fontWeight(.bold)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.secondary.opacity(0.1))
                                .cornerRadius(4)

                            Spacer()

                            if isClaimed {
                                Text("Claimed!")
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.green)
                            } else if eval.isComplete {
                                Button {
                                    claimBonus(objective: objective)
                                } label: {
                                    HStack {
                                        Text("Claim")
                                        Text("💎 \(objective.gemReward)")
                                    }
                                    .font(.caption.bold())
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Color.gold)
                                .disabled(isClaiming)
                                .overlay {
                                    if showConfetti {
                                        ClaimConfettiView()
                                            .allowsHitTesting(false)
                                    }
                                }
                            } else {
                                HStack {
                                    Text("Reward:")
                                    Text("💎 \(objective.gemReward)")
                                }
                                .font(.caption.bold())
                                .foregroundStyle(Color.gold)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(DesignSystemConstants.CornerRadius.small)
                }
            }
        }
        .padding()
        .background(Color(UIColor.systemGroupedBackground))
        .cornerRadius(DesignSystemConstants.CornerRadius.card)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { break }
                withAnimation(.easeInOut(duration: 0.5)) {
                    frameIndex = (frameIndex + 1) % 2
                }
            }
        }
    }

    private func currentMascotState() -> MascotState {
        let total = quests.count
        let completed = completions.count

        if total == 0 {
            return .idle
        }
        if completed >= total {
            return .celebrating
        }
        if completed > 0 {
            return .inProgress
        }
        return .idle
    }

    private func claimBonus(objective: BonusObjective) {
        isClaiming = true
        withAnimation { showConfetti = true }

        Task {
            do {
                try await bonusService.claimObjective(objective: objective, profile: profile, gemService: gemService, soundManager: soundManager)
                // Let confetti play
                try await Task.sleep(for: .seconds(2))
            } catch {
                // handle error
            }
            isClaiming = false
            showConfetti = false
        }
    }

    @ViewBuilder
    private func mascotSprite(companion: MascotCompanion, state: MascotState) -> some View {
        let spriteData = MascotSpriteRenderer.sprite(for: companion, state: state, frameIndex: frameIndex)
        PixelCanvasView(sprite: spriteData, animated: false)
    }
}

/// Simple local confetti burst
private struct ClaimConfettiView: View {
    @State private var start: Date?

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                guard let start else { return }
                let elapsed = timeline.date.timeIntervalSince(start)
                let duration = 1.0
                guard elapsed <= duration else { return }

                let progress = elapsed / duration
                for sparkIndex in 0 ..< 12 {
                    let angle = Double(sparkIndex) * (.pi * 2 / 12)
                    let dist = progress * 60
                    let particleX = size.width / 2 + cos(angle) * dist
                    let particleY = size.height / 2 + sin(angle) * dist
                    let opacity = 1 - progress

                    let colors: [Color] = [.red, .blue, .green, .yellow, .purple, .orange]
                    let color = colors[sparkIndex % colors.count]

                    var localCtx = ctx
                    localCtx.translateBy(x: particleX, y: particleY)
                    localCtx.rotate(by: .degrees(progress * 180))
                    let rect = CGRect(x: -3, y: -3, width: 6, height: 6)
                    localCtx.fill(Path(rect), with: .color(color.opacity(opacity)))
                }
            }
        }
        .onAppear { start = Date() }
    }
}
