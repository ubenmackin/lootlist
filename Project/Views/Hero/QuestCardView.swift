//
//  QuestCardView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import SwiftUI

struct QuestCardView: View {
    let quest: QuestCache
    var logs: [QuestCompletionCache] = []
    var isOverdue: Bool = false
    var onComplete: (() -> Void)?

    @State private var showCompletionEffect: Bool = false

    private var approvedCount: Int {
        logs.filter {
            $0.verificationStatus == VerificationStatus.verified.rawValue
                || $0.verificationStatus == VerificationStatus.autoApproved.rawValue
        }.count
    }

    private var targetCount: Int {
        max(1, quest.targetCount)
    }

    private var isFullyCompleted: Bool {
        GoldCalculation.isFullyCompleted(quest: quest, approvedCount: approvedCount)
    }

    private var isPendingReview: Bool {
        !isFullyCompleted && logs.contains { $0.verificationStatus == VerificationStatus.pending.rawValue }
    }

    private var cardBackgroundColor: Color {
        if isFullyCompleted {
            Color(DesignSystemConstants.Colors.primaryGreen).opacity(0.12)
        } else if isPendingReview {
            Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.12)
        } else if isOverdue {
            Color(DesignSystemConstants.Colors.dangerRed).opacity(0.10)
        } else {
            Color(DesignSystemConstants.Colors.cardSurface)
        }
    }

    var body: some View {
        let approvalMode = quest.approvalModeEnum ?? .autoApprove
        let rarity = QuestRarity.from(xp: quest.xpReward)

        let cardContent = VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: isFullyCompleted ? "checkmark.circle.fill" : (isPendingReview ? "hourglass.circle.fill" : approvalMode.iconSystemName))
                    .font(.title3)
                    .foregroundStyle(isFullyCompleted ? Color(DesignSystemConstants.Colors.primaryGreen) :
                        (isPendingReview ? Color(DesignSystemConstants.Colors.pendingAmber) :
                            (approvalMode == .parentVerify ? Color(DesignSystemConstants.Colors.accentBlue) : Color(DesignSystemConstants.Colors.primaryGreen))))
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill((isFullyCompleted ? Color(DesignSystemConstants.Colors.primaryGreen) :
                                    (isPendingReview ? Color(DesignSystemConstants.Colors.pendingAmber) :
                                        (approvalMode == .parentVerify ? Color(DesignSystemConstants.Colors.accentBlue) : Color(DesignSystemConstants.Colors.primaryGreen))))
                                .opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(quest.questName)
                            .font(.headline)
                            .foregroundStyle(isFullyCompleted ? .secondary : .primary)

                        // WHY: rarity icon/color is legacy RPG chrome — hidden behind FeatureFlags.rpgImmersive per ARCHITECTURE.md §1 gamification contract.
                        if FeatureFlags.rpgImmersive, rarity != .common {
                            Image(systemName: rarity.iconSystemName)
                                .font(.caption2)
                                .foregroundStyle(rarity.color)
                        }

                        if isOverdue, !isFullyCompleted {
                            Text("⚠️ Overdue")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.2)))
                                .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))
                        }
                    }

                    HStack(spacing: 10) {
                        Label(CurrencyFormatter.string(quest.goldReward), systemImage: "banknote")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline)
                            .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))

                        if isPendingReview {
                            Text("⏳ Awaiting Review")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.2)))
                                .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))
                        } else if approvalMode == .parentVerify {
                            Text("Parent Verifies")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color(DesignSystemConstants.Colors.accentBlue).opacity(0.15)))
                                .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                        }
                    }
                }

                Spacer()

                if targetCount <= 1 {
                    Button {
                        if !isFullyCompleted, !isPendingReview {
                            showCompletionEffect = true
                            onComplete?()
                        }
                    } label: {
                        Image(systemName: isFullyCompleted ? "checkmark.seal.fill" : (isPendingReview ? "hourglass.circle.fill" : "circle"))
                            .font(.title2)
                            .foregroundStyle(isFullyCompleted ? Color(DesignSystemConstants.Colors.primaryGreen) :
                                (isPendingReview ? Color(DesignSystemConstants.Colors.pendingAmber) : Color(DesignSystemConstants.Colors.accentBlue)))
                    }
                    .buttonStyle(.plain)
                    .disabled(isFullyCompleted || isPendingReview)
                }
            }

            if targetCount > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Progress: \(approvedCount)/\(targetCount) completed")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Spacer()
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(0 ..< targetCount, id: \.self) { index in
                                let isDone = index < approvedCount
                                let isPendingSlot = isPendingReview && index == approvedCount
                                let isNextToLog = index == approvedCount && !isPendingReview

                                Button {
                                    if isNextToLog {
                                        showCompletionEffect = true
                                        onComplete?()
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: isDone ? "checkmark.circle.fill" : (isPendingSlot ? "hourglass" : (isNextToLog ? "plus.circle.fill" : "circle")))
                                            .font(.caption)
                                        Text(isDone ? "Slot \(index + 1) ✓" : (isPendingSlot ? "Pending ⏳" : (isNextToLog ? "Log #\(index + 1)" : "Slot \(index + 1)")))
                                            .font(.caption.bold())
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        Capsule()
                                            .fill(isDone ? Color(DesignSystemConstants.Colors.primaryGreen)
                                                .opacity(0.2) :
                                                (isPendingSlot ? Color(DesignSystemConstants.Colors.pendingAmber)
                                                    .opacity(0.2) : (isNextToLog ? Color(DesignSystemConstants.Colors.accentBlue).opacity(0.2) : Color.secondary.opacity(0.12))))
                                    )
                                    .foregroundStyle(isDone ? Color(DesignSystemConstants.Colors.primaryGreen) :
                                        (isPendingSlot ? Color(DesignSystemConstants.Colors.pendingAmber) :
                                            (isNextToLog ? Color(DesignSystemConstants.Colors.accentBlue) : Color.secondary)))
                                }
                                .buttonStyle(.plain)
                                .disabled(!isNextToLog)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(cardBackgroundColor)
        )

        // WHY: rarity border is legacy RPG chrome — gated behind FeatureFlags.rpgImmersive so default view stays utility-first (ARCHITECTURE.md §1).
        Group {
            if FeatureFlags.rpgImmersive {
                cardContent.rarityBorder(rarity)
            } else {
                cardContent
            }
        }
        .overlay(
            QuestCompletionEffectView(
                xpEarned: quest.xpReward,
                goldEarned: quest.goldReward > 0 ? quest.goldReward : nil,
                // WHY: pass neutral rarity when immersive off so celebration stays plain-warm and never leaks RPG tier visuals.
                rarity: FeatureFlags.rpgImmersive ? rarity : .common,
                isShowing: $showCompletionEffect
            )
        )
        .contentShape(Rectangle())
    }
}
