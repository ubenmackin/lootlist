//
//  ChoreRowCard.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import SwiftUI

/// A single chore row on the child hub. Two visual states: an amber
/// pending-review row (done from the child's perspective, waiting on a
/// parent) and a neutral upcoming row with a green amount pill.
struct ChoreRowCard: View {
    enum RowStyle {
        case pendingReview
        case upcoming
    }

    let title: String

    var subtitle: String?

    let amountText: String

    let style: RowStyle

    var body: some View {
        HStack(spacing: DesignSystemConstants.Padding.medium) {
            leadingIcon

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(style == .pendingReview ? Color(DesignSystemConstants.Colors.pendingAmber) : Color.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: DesignSystemConstants.Padding.small)

            amountView
        }
        .padding(DesignSystemConstants.Padding.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay {
            if style == .pendingReview {
                RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small, style: .continuous)
                    .strokeBorder(Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.45), lineWidth: 1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var leadingIcon: some View {
        switch style {
        case .pendingReview:
            Image(systemName: "clock")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color(DesignSystemConstants.Colors.pendingAmber)))
        case .upcoming:
            Circle()
                .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 2)
                .frame(width: 32, height: 32)
        }
    }

    @ViewBuilder
    private var amountView: some View {
        switch style {
        case .pendingReview:
            Text(amountText)
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Color(DesignSystemConstants.Colors.pendingAmber))
        case .upcoming:
            Text(amountText)
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color(DesignSystemConstants.Colors.primaryGreen)))
        }
    }

    private var backgroundColor: Color {
        style == .pendingReview
            ? Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.12)
            : Color(.tertiarySystemGroupedBackground)
    }
}
