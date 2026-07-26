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

    var body: some View {
        let approvalMode = quest.approvalModeEnum
        let rarity = quest.rarityEnum

        HStack(spacing: 12) {
            Image(systemName: approvalMode.iconSystemName)
                .font(.title3)
                .foregroundStyle(approvalMode == .parentVerify ? .indigo : .green)
                .frame(width: 32, height: 32)
                .background(
                    Circle()
                        .fill((approvalMode == .parentVerify ? Color.indigo : Color.green)
                            .opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(quest.questName)
                    .font(.headline)
                HStack(spacing: 10) {
                    Label(String(format: "%.2f", quest.goldReward), systemImage: "dollarsign.circle.fill")
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

            Image(systemName: "chevron.right")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .contentShape(Rectangle())
    }

    private var templateNameGuess: String {
        let name = quest.templateRecordName
        if name.count > 6 {
            return String(name.suffix(6))
        }
        return name
    }
}
