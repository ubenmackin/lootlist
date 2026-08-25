//
//  GoalCardView.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import SwiftUI

/// A savings goal card showing the emoji, name, progress bar, and a dual
/// footer row (% earned + dollar amount remaining).
struct GoalCardView: View {
    let emoji: String

    let name: String

    let savedAmount: Double

    let targetAmount: Double

    private var progress: Double {
        guard targetAmount > 0 else { return 0 }
        return min(max(savedAmount / targetAmount, 0), 1)
    }

    private var percentText: String {
        "\(Int((progress * 100).rounded()))% earned"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Emoji + title row
            HStack(spacing: 8) {
                Text(emoji)
                    .font(.title2)

                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()
            }

            // Saved / Target status line
            HStack(spacing: 4) {
                Text(savedAmount, format: .currency(code: "USD"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))

                Text("of")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(targetAmount, format: .currency(code: "USD"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(DesignSystemConstants.Colors.primaryGreen).opacity(0.15))
                        .frame(height: 8)

                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(DesignSystemConstants.Colors.primaryGreen))
                        .frame(width: geometry.size.width * progress, height: 8)
                }
            }
            .frame(height: 8)

            // Footer: % earned | $ left
            HStack {
                Text(percentText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))

                Spacer()

                Text("$\(formattedCurrency(targetAmount - savedAmount)) left")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(DesignSystemConstants.Padding.medium)
        .background(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small,
                             style: .continuous)
                .fill(Color(DesignSystemConstants.Colors.cardSurface))
        )
    }

    /// Simple USD formatting — callers that need region-aware formatting
    /// should use CurrencyFormatter instead.
    private func formattedCurrency(_ value: Double) -> String {
        let clamped = max(value, 0)
        return String(format: "%.2f", clamped)
    }
}
