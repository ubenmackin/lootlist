//
//  PresetPill.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import SwiftUI

struct PresetPill: View {
    var text: String
    var isSelected: Bool
    var action: () -> Void
    var systemImage: String?
    var color: Color?

    init(
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

    var body: some View {
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
