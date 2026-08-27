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
        case completed
    }

    let title: String

    var subtitle: String?

    let amountText: String

    let style: RowStyle

    var isSubmitting: Bool = false

    var onLeadingAction: (() -> Void)?

    var accessibilityID: String?

    var body: some View {
        HStack(spacing: DesignSystemConstants.Padding.medium) {
            leadingIcon

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(style == .completed ? .secondary : .primary)
                    .strikethrough(style == .completed, color: .secondary.opacity(0.5))
                    .lineLimit(1)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(subtitleColor)
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
        .accessibilityIdentifierIfSet(accessibilityID)
    }

    @ViewBuilder
    private var leadingIcon: some View {
        switch style {
        case .pendingReview:
            if let onLeadingAction {
                Button(action: onLeadingAction) {
                    ZStack {
                        Circle()
                            .fill(Color(DesignSystemConstants.Colors.pendingAmber))
                            .frame(width: 32, height: 32)
                        if isSubmitting {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        } else {
                            Image(systemName: "clock.fill")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting)
                .accessibilityLabel("Pending parent review for \(title)")
            } else {
                Image(systemName: "clock.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color(DesignSystemConstants.Colors.pendingAmber)))
            }
        case .upcoming:
            if let onLeadingAction {
                Button(action: onLeadingAction) {
                    ZStack {
                        Circle()
                            .strokeBorder(Color(DesignSystemConstants.Colors.primaryGreen), lineWidth: 2)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Color(DesignSystemConstants.Colors.primaryGreen).opacity(0.12)))

                        if isSubmitting {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Color(DesignSystemConstants.Colors.primaryGreen))
                        }
                    }
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting)
                .accessibilityLabel("Complete \(title)")
            } else {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 2)
                    .frame(width: 32, height: 32)
            }
        case .completed:
            ZStack {
                Circle()
                    .fill(Color(DesignSystemConstants.Colors.primaryGreen))
                    .frame(width: 32, height: 32)
                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
            }
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
        case .completed:
            Text(amountText)
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Color(DesignSystemConstants.Colors.primaryGreen))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color(DesignSystemConstants.Colors.primaryGreen).opacity(0.15)))
        }
    }

    private var subtitleColor: Color {
        switch style {
        case .pendingReview:
            Color(DesignSystemConstants.Colors.pendingAmber)
        case .upcoming:
            Color.secondary
        case .completed:
            Color(DesignSystemConstants.Colors.primaryGreen)
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .pendingReview:
            Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.12)
        case .upcoming:
            Color(.tertiarySystemGroupedBackground)
        case .completed:
            Color(.secondarySystemGroupedBackground).opacity(0.7)
        }
    }
}
