import SwiftUI

enum BadgeSize: Sendable {
    case small
    case medium
    case large

    var glyphSize: CGFloat {
        switch self {
        case .small: 11
        case .medium: 14
        case .large: 18
        }
    }

    var valueFont: Font {
        switch self {
        case .small: .caption2.weight(.bold)
        case .medium: .caption.weight(.bold)
        case .large: .callout.weight(.bold)
        }
    }

    var hPadding: CGFloat {
        switch self {
        case .small: 6
        case .medium: 8
        case .large: 10
        }
    }

    var vPadding: CGFloat {
        switch self {
        case .small: 3
        case .medium: 4
        case .large: 6
        }
    }

    var spacing: CGFloat {
        switch self {
        case .small: 3
        case .medium: 5
        case .large: 7
        }
    }
}

struct GoldBadge: View {
    let amount: Double?

    var size: BadgeSize = .medium

    var format: ((Double) -> String)?

    var body: some View {
        HStack(spacing: size.spacing) {
            Image(systemName: Self.coinSystemName)
                .font(.system(size: size.glyphSize, weight: .bold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.gold)
            Text(amountText)
                .font(size.valueFont)
                .monospacedDigit()
                .foregroundStyle(amount == nil ? Color.secondary : Color.primary)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, size.hPadding)
        .padding(.vertical, size.vPadding)
        .background(
            Capsule().fill(Color.gold.opacity(0.14))
        )
        .overlay(
            Capsule()
                .strokeBorder(Color.gold.opacity(0.45), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    static let coinSystemName = "circle.hexagongrid.fill"

    private var amountText: String {
        guard let amount else { return "—" }
        return format?(amount) ?? Self.defaultFormat(amount)
    }

    private var accessibilityLabel: String {
        guard amount != nil else { return "Gold loading" }
        return "Gold \(amountText)"
    }

    private static func defaultFormat(_ amount: Double) -> String {
        NumberFormatter.goldFormatter.string(from: NSNumber(value: abs(amount))) ?? "0.00"
    }
}
