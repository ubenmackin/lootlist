//
//  GoldBadge.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

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

struct MoneyBadge: View {
    let amount: Double?
    let pennies: Int64?

    var size: BadgeSize = .medium

    init(amount: Double?, size: BadgeSize = .medium) {
        self.amount = amount
        self.pennies = nil
        self.size = size
    }

    init(amount: Int64?, size: BadgeSize = .medium) {
        self.amount = nil
        self.pennies = amount
        self.size = size
    }

    var body: some View {
        HStack(spacing: size.spacing) {
            Text(amountText)
                .font(size.valueFont)
                .monospacedDigit()
                .foregroundStyle((amount == nil && pennies == nil) ? Color.secondary : Color.primary)
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

    private var amountText: String {
        if let pennies {
            return CurrencyFormatter.magnitude(pennies: pennies)
        }
        guard let amount else { return "—" }
        return CurrencyFormatter.magnitude(amount)
    }

    private var accessibilityLabel: String {
        guard amount != nil || pennies != nil else { return "Money loading" }
        return "Money \(amountText)"
    }
}
