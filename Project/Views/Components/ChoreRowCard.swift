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
        case expired
    }

    let title: String

    var subtitle: String?

    let amountText: String

    let style: RowStyle

    var isSubmitting: Bool = false

    var isMultiPart: Bool = false

    var onLeadingAction: (() -> Void)?

    var accessibilityID: String?

    var body: some View {
        HStack(alignment: .top, spacing: DesignSystemConstants.Padding.medium) {
            leadingIcon

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(style == .completed || style == .expired ? .secondary : .primary)
                    .strikethrough(style == .completed, color: .secondary.opacity(0.5))
                    .lineLimit(2)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(subtitleColor)
                        .lineLimit(2)
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
                    leadingBadge(isMultiPart: isMultiPart, isSubmitting: isSubmitting)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting)
                .accessibilityLabel("Complete \(title)")
            } else {
                leadingBadge(isMultiPart: isMultiPart, isSubmitting: isSubmitting)
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
        case .expired:
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: 32, height: 32)
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func leadingBadge(isMultiPart: Bool, isSubmitting: Bool) -> some View {
        ZStack {
            if isMultiPart {
                Circle()
                    .fill(Color(DesignSystemConstants.Colors.accentBlue).opacity(0.16))
                    .frame(width: 32, height: 32)
                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color(DesignSystemConstants.Colors.accentBlue))
                } else {
                    Image(systemName: "checklist")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color(DesignSystemConstants.Colors.accentBlue))
                }
            } else {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.4), lineWidth: 2)
                    .frame(width: 32, height: 32)
                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.secondary)
                }
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
        case .expired:
            Text(amountText)
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
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
        case .expired:
            Color.secondary
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
        case .expired:
            Color(.secondarySystemGroupedBackground).opacity(0.55)
        }
    }
}
