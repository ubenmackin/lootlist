//
//  BucketTileView.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import SwiftUI

/// Frosted sub-tile rendered inside the balance hero card with primary tap action.
struct BucketTileView: View {
    let emoji: String?

    let title: String

    let amountText: String

    var accessibilityID: String?

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                if let emoji, !emoji.isEmpty {
                    Text(emoji)
                }
                Text(title)
            }
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
        .accessibilityIdentifierIfSet(accessibilityID)
    }
}
