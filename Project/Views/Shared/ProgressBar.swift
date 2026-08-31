//
//  ProgressBar.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import SwiftUI

struct ProgressBar: View {
    let value: Double

    let maximum: Double

    let label: String?

    var tint: Color = .init(DesignSystemConstants.Colors.accentBlue)

    var height: CGFloat = 8

    @State private var appeared: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            track
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label ?? "Progress")
        .accessibilityValue("\(Int(fraction * 100)) percent")
        .onAppear { animateFill() }
        .onChange(of: value) { _, _ in animateFill() }
        .onChange(of: maximum) { _, _ in animateFill() }
    }

    private var track: some View {
        GeometryReader { proxy in
            let rawWidth = proxy.size.width
            let trackWidth: CGFloat = (rawWidth.isFinite && rawWidth > 0) ? rawWidth : 0
            let fillWidth: CGFloat = trackWidth * CGFloat(currentFraction)
            let safeFillWidth: CGFloat = (fillWidth.isFinite && fillWidth > 0) ? fillWidth : 0
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackFill)
                    .frame(width: trackWidth, height: height)

                Capsule()
                    .fill(tint)
                    .frame(width: safeFillWidth, height: height)
                    .shadow(color: tint.opacity(0.45), radius: 4, y: 1)
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
    }

    private var trackFill: some ShapeStyle {
        LinearGradient(
            colors: [
                Color.secondary.opacity(0.18),
                Color.secondary.opacity(0.10)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var fraction: Double {
        guard maximum > 0, maximum.isFinite, value.isFinite else { return 0 }
        let rawFraction = value / maximum
        guard rawFraction.isFinite else { return 0 }
        return min(max(rawFraction, 0.0), 1.0)
    }

    private var currentFraction: Double {
        appeared ? fraction : 0
    }

    private func animateFill() {
        withAnimation(.easeInOut(duration: DesignSystemConstants.AnimationDuration.progressFill)) {
            appeared = true
        }
    }
}
