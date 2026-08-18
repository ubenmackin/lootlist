//
//  QuestCardView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
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
            Color.green.opacity(0.12)
        } else if isPendingReview {
            Color.purple.opacity(0.12)
        } else if isOverdue {
            Color.red.opacity(0.10)
        } else {
            Color(.secondarySystemGroupedBackground)
        }
    }

    var body: some View {
        let approvalMode = quest.approvalModeEnum ?? .autoApprove
        let rarity = QuestRarity.from(xp: quest.xpReward)

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: isFullyCompleted ? "checkmark.circle.fill" : (isPendingReview ? "hourglass.circle.fill" : approvalMode.iconSystemName))
                    .font(.title3)
                    .foregroundStyle(isFullyCompleted ? .green : (isPendingReview ? .purple : (approvalMode == .parentVerify ? .indigo : .green)))
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill((isFullyCompleted ? Color.green : (isPendingReview ? Color.purple : (approvalMode == .parentVerify ? Color.indigo : Color.green)))
                                .opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(quest.questName)
                            .font(.headline)
                            .foregroundStyle(isFullyCompleted ? .secondary : .primary)

                        if rarity != .common {
                            Image(systemName: rarity.iconSystemName)
                                .font(.caption2)
                                .foregroundStyle(rarity.color)
                        }

                        if isOverdue, !isFullyCompleted {
                            Text("⚠️ Overdue")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.orange.opacity(0.2)))
                                .foregroundStyle(.orange)
                        }
                    }

                    HStack(spacing: 10) {
                        Label(CurrencyFormatter.string(quest.goldReward), systemImage: "banknote")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline)
                            .foregroundStyle(.yellow)

                        if isPendingReview {
                            Text("⏳ Awaiting Review")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.purple.opacity(0.2)))
                                .foregroundStyle(.purple)
                        } else if approvalMode == .parentVerify {
                            Text("Parent Verifies")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.indigo.opacity(0.15)))
                                .foregroundStyle(.indigo)
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
                            .foregroundStyle(isFullyCompleted ? .green : (isPendingReview ? .purple : .accentColor))
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
                                            .fill(isDone ? Color.green
                                                .opacity(0.2) :
                                                (isPendingSlot ? Color.purple.opacity(0.2) : (isNextToLog ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.12))))
                                    )
                                    .foregroundStyle(isDone ? Color.green : (isPendingSlot ? Color.purple : (isNextToLog ? Color.accentColor : Color.secondary)))
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
        .rarityBorder(rarity)
        .overlay(
            QuestCompletionEffectView(
                xpEarned: quest.xpReward,
                goldEarned: quest.goldReward > 0 ? quest.goldReward : nil,
                rarity: rarity,
                isShowing: $showCompletionEffect
            )
        )
        .contentShape(Rectangle())
    }
}
