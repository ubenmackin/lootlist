import SwiftUI

struct StreakBadge: View {

    let streak: Int

    var size: BadgeSize = .medium

    var body: some View {
        HStack(spacing: size.spacing) {
            flameGlyph
            Text(countText)
                .font(size.valueFont)
                .monospacedDigit()
                .foregroundStyle(active ? Color.primary : Color.secondary)
        }
        .padding(.horizontal, size.hPadding)
        .padding(.vertical, size.vPadding)
        .background(
            Capsule().fill(active ? Color.orange.opacity(0.14) : Color.secondary.opacity(0.12))
        )
        .overlay(
            Capsule()
                .strokeBorder(active ? Color.orange.opacity(0.55) : Color.secondary.opacity(0.20),
                                lineWidth: 1)
        )
        .opacity(active ? 1.0 : 0.60)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var active: Bool { streak >= 1 }

    private var flameGlyph: some View {
        Image(systemName: "flame.fill")
            .font(.system(size: size.glyphSize, weight: .bold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(
                LinearGradient(
                    colors: active
                        ? [Color.red, Color.orange]
                        : [Color.secondary, Color.secondary.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }

    private var countText: String {
        streak > 0 ? "\(streak)" : "—"
    }

    private var accessibilityLabel: String {
        streak > 0
            ? "Combo streak \(streak) days"
            : "No active streak"
    }
}
