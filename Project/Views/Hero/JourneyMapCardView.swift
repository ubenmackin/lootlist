//
//  JourneyMapCardView.swift
//  LootList
//
//  Created by Ben Mackin on 8/22/26.
//

import SwiftUI

/// Compact card on the Hero Dashboard showing the hero's current zone and a
/// mini path preview. Tapping opens the full-screen `JourneyMapView`.
struct JourneyMapCardView: View {
    let journeyState: JourneyState
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                zoneIcon
                zoneInfo
                Spacer(minLength: 0)
                miniPathPreview
                chevron
            }
            .padding(DesignSystemConstants.Padding.standard)
            .background(
                RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
                    .fill(cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.card, style: .continuous)
                    .strokeBorder(
                        journeyState.currentZone.palette.accentColor.opacity(0.35),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Tap to explore the journey map")
    }

    // MARK: - Zone Icon

    private var zoneIcon: some View {
        Image(systemName: journeyState.currentZone.iconSystemName)
            .font(.title2.weight(.semibold))
            .foregroundStyle(journeyState.currentZone.palette.accentColor)
            .frame(width: 36, height: 36)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(journeyState.currentZone.palette.accentColor.opacity(0.15))
            )
    }

    // MARK: - Zone Info

    private var zoneInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(journeyState.currentZone.shortName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text("Level \(journeyState.currentLevel)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Mini Path Preview

    /// Shows a compact row of 5 milestone dots around the current level.
    private var miniPathPreview: some View {
        let dots = miniDots
        return HStack(spacing: 4) {
            ForEach(dots, id: \.level) { milestone in
                Circle()
                    .fill(dotColor(for: milestone))
                    .frame(
                        width: milestone.state == .current ? 8 : 5,
                        height: milestone.state == .current ? 8 : 5
                    )
            }
        }
    }

    /// Selects up to 5 milestones centered around the current level for the mini preview.
    private var miniDots: [JourneyMilestone] {
        let current = journeyState.currentLevel
        let start = max(1, current - 2)
        let end = start + 4
        return journeyState.milestones.filter { $0.level >= start && $0.level <= end }
    }

    private func dotColor(for milestone: JourneyMilestone) -> Color {
        switch milestone.state {
        case .reached: Color.gold
        case .current: journeyState.currentZone.palette.accentColor
        case .future: Color(.tertiarySystemFill)
        }
    }

    // MARK: - Chevron

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
    }

    // MARK: - Background

    private var cardBackground: LinearGradient {
        let palette = journeyState.currentZone.palette
        return LinearGradient(
            colors: [
                palette.groundColor.opacity(0.08),
                Color(.secondarySystemGroupedBackground)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    // MARK: - Accessibility

    private var accessibilityLabel: String {
        "Journey Map. Currently in \(journeyState.currentZone.displayName), level \(journeyState.currentLevel)."
    }
}
