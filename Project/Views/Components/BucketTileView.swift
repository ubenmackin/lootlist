//
//  BucketTileView.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import SwiftUI

/// Frosted sub-tile rendered inside the green balance hero card. Sits on a
/// saturated gradient, so text is fixed white rather than semantic — the card
/// behind it is the same in light and dark mode.
struct BucketTileView: View {
    let emoji: String

    let title: String

    let amountText: String

    var body: some View {
        VStack(spacing: 4) {
            Text("\(emoji) \(title)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(amountText)
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.small, style: .continuous)
                .fill(Color.white.opacity(0.18))
        )
    }
}
