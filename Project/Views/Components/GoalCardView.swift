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
    var targetDate: Date?
    var createdAt: Date = .init()
    var linkURL: String?
    var isCompleted: Bool = false
    var accessibilityID: String?

    private var progress: Double {
        guard targetAmount > 0 else { return 0 }
        return min(max(savedAmount / targetAmount, 0), 1)
    }

    private var percentText: String {
        "\(Int((progress * 100).rounded()))% earned"
    }

    private var pacingSummary: GoalPacingCalculator.PacingSummary? {
        GoalPacingCalculator.calculatePacing(
            targetAmountPennies: Int64((targetAmount * 100).rounded()),
            savedPennies: Int64((savedAmount * 100).rounded()),
            createdAt: createdAt,
            targetDate: targetDate,
            completedAt: isCompleted ? Date() : nil
        )
    }

    private var validWebURL: URL? {
        guard let linkURL else { return nil }
        return LinkMetadataService.normalizeURL(from: linkURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Emoji + title row + optional store link
            HStack(spacing: 8) {
                Text(emoji)
                    .font(.title2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let summary = pacingSummary, summary.status != .noDeadline {
                        HStack(spacing: 4) {
                            Image(systemName: summary.status.iconSystemName)
                                .font(.caption2)
                            Text(summary.status.badgeText)
                                .font(.caption2.weight(.bold))
                        }
                        .foregroundStyle(summary.status.tintColor)
                    }
                }

                Spacer()

                if let validWebURL {
                    Link(destination: validWebURL) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.subheadline)
                            .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                            .padding(4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("View \(name) online")
                }
            }

            // Saved / Target status line
            HStack(spacing: 4) {
                Text(CurrencyFormatter.string(savedAmount))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))

                Text("of")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(CurrencyFormatter.string(targetAmount))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let summary = pacingSummary, summary.status != .completed {
                    Spacer()
                    Text(summary.formattedTargetDate)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(DesignSystemConstants.Colors.primaryGreen).opacity(0.15))
                        .frame(height: 8)

                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(DesignSystemConstants.Colors.primaryGreen))
                        .frame(width: max(0, geometry.size.width * progress), height: 8)
                }
            }
            .frame(height: 8)

            // Footer: % earned | remaining / pacing note
            HStack {
                Text(percentText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))

                Spacer()

                if let summary = pacingSummary, summary.status != .completed, summary.daysRemaining > 7 {
                    Text("Save \(CurrencyFormatter.string(summary.weeklyRequiredSavingsDollars))/wk")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(summary.status.tintColor)
                } else {
                    Text("\(CurrencyFormatter.string(max(targetAmount - savedAmount, 0))) left")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(DesignSystemConstants.Padding.medium)
        .background(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small,
                             style: .continuous)
                .fill(Color(DesignSystemConstants.Colors.cardSurface))
        )
        .accessibilityIdentifierIfSet(accessibilityID)
    }
}
