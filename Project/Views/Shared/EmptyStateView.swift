//
//  EmptyStateView.swift
//  LootList
//
//  Created by Ben Mackin on 8/13/26.
//

import SwiftUI

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let description: String
    var topPadding: CGFloat = 32
    var bottomPadding: CGFloat = 0
    var verticalPadding: CGFloat?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DesignSystemConstants.Padding.large)
        }
        .maxBannerWidth()
        .modifier(EmptyStatePaddingModifier(
            topPadding: topPadding,
            bottomPadding: bottomPadding,
            verticalPadding: verticalPadding
        ))
    }
}

private struct EmptyStatePaddingModifier: ViewModifier {
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    let verticalPadding: CGFloat?

    func body(content: Content) -> some View {
        if let verticalPadding {
            content.padding(.vertical, verticalPadding)
        } else {
            content
                .padding(.top, topPadding)
                .padding(.bottom, bottomPadding)
        }
    }
}
