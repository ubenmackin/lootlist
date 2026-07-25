//
//  PresetPill.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import SwiftUI

/// A capsule-shaped preset chip used to quickly pick a canned value
/// (e.g. gold reward presets, rarity selectors). `isSelected` highlights
/// the active preset. Optional `systemImage` renders a leading SF Symbol
/// and optional `color` overrides the accent fill (used for per-rarity chips).
public struct PresetPill: View {
    public var text: String
    public var isSelected: Bool
    public var action: () -> Void
    public var systemImage: String?
    public var color: Color?

    public init(
        text: String,
        isSelected: Bool,
        action: @escaping () -> Void,
        systemImage: String? = nil,
        color: Color? = nil
    ) {
        self.text = text
        self.isSelected = isSelected
        self.action = action
        self.systemImage = systemImage
        self.color = color
    }

    public var body: some View {
        let fill = (color ?? Color.accentColor).opacity(isSelected ? 0.35 : 0.15)
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption2)
                }
                Text(text)
                    .font(.caption.bold())
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(fill))
        }
        .buttonStyle(.plain)
    }
}
