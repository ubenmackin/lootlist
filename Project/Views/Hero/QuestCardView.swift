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

    var body: some View {
        let approvalMode = quest.approvalModeEnum ?? .autoApprove
        let rarity = quest.rarityEnum ?? .common

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: isFullyCompleted ? "checkmark.circle.fill" : approvalMode.iconSystemName)
                    .font(.title3)
                    .foregroundStyle(isFullyCompleted ? .green : (approvalMode == .parentVerify ? .indigo : .green))
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill((isFullyCompleted ? Color.green : (approvalMode == .parentVerify ? Color.indigo : Color.green))
                                .opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(quest.questName)
                            .font(.headline)
                            .strikethrough(isFullyCompleted, color: .secondary)
                            .foregroundStyle(isFullyCompleted ? .secondary : .primary)

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

                        Label("\(rarity.rawValue) · \(quest.xpReward) XP", systemImage: rarity.iconSystemName)
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline)
                            .foregroundStyle(rarity.color)

                        if approvalMode == .parentVerify {
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
                        if !isFullyCompleted {
                            onComplete?()
                        }
                    } label: {
                        Image(systemName: isFullyCompleted ? "checkmark.seal.fill" : "circle")
                            .font(.title2)
                            .foregroundStyle(isFullyCompleted ? .green : .accentColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(isFullyCompleted)
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
                                let isNextToLog = index == approvedCount

                                Button {
                                    if isNextToLog {
                                        onComplete?()
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: isDone ? "checkmark.circle.fill" : (isNextToLog ? "plus.circle.fill" : "circle"))
                                            .font(.caption)
                                        Text(isDone ? "Slot \(index + 1) ✓" : (isNextToLog ? "Log #\(index + 1)" : "Slot \(index + 1)"))
                                            .font(.caption.bold())
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        Capsule()
                                            .fill(isDone ? Color.green.opacity(0.2) : (isNextToLog ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.12)))
                                    )
                                    .foregroundStyle(isDone ? Color.green : (isNextToLog ? Color.accentColor : Color.secondary))
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
                .fill(Color(.secondarySystemGroupedBackground))
                .opacity(isFullyCompleted ? 0.75 : 1.0)
        )
        .contentShape(Rectangle())
    }
}
