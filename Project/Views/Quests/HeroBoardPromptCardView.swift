//
//  HeroBoardPromptCardView.swift
//  LootList
//
//  Created by Ben Mackin on 10/18/26.
//

import SwiftUI

/// Dashboard card advertising unclaimed Hero Board quests. Surfaces omit it
/// entirely at a zero count instead of rendering an empty shell.
struct HeroBoardPromptCardView: View {
    let availableQuestCount: Int

    private var headline: String {
        if availableQuestCount == 1 {
            return "1 quest on the Hero Board"
        }
        return "\(availableQuestCount) quests on the Hero Board"
    }

    var body: some View {
        NavigationLink(value: "heroBoard") {
            HStack(spacing: DesignSystemConstants.Padding.medium) {
                Image(systemName: "sparkles")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color(DesignSystemConstants.Colors.gold))
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(DesignSystemConstants.Colors.gold).opacity(0.15))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text("Up for grabs — claim one!")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(DesignSystemConstants.Padding.standard)
            .background(
                RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
                    .fill(Color(DesignSystemConstants.Colors.cardSurface))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
                    .strokeBorder(Color(DesignSystemConstants.Colors.gold).opacity(0.30), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the Hero Board")
        .accessibilityIdentifier("heroBoard.promptCard")
    }
}
