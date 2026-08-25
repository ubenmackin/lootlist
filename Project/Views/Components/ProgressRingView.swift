//
//  ProgressRingView.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import SwiftUI

/// Circular momentum ring used for weekly chore goals and budget targets.
/// Progress is clamped to [0, 1] so a data anomaly can never render an
/// over-wound arc.
struct ProgressRingView: View {
    let progress: Double

    var tint: Color = .init(DesignSystemConstants.Colors.primaryGreen)

    var lineWidth: CGFloat = 8

    var identifier: String?

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }

    private var percentText: String {
        "\(Int((clampedProgress * 100).rounded()))%"
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(.tertiarySystemFill), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: clampedProgress)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(
                    .easeInOut(duration: DesignSystemConstants.AnimationDuration.progressFill),
                    value: clampedProgress
                )

            Text(percentText)
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress")
        .accessibilityValue(percentText)
        .accessibilityIdentifierIfSet(identifier)
    }
}
