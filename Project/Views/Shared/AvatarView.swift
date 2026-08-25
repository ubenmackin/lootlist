//
//  AvatarView.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import SwiftUI
import UIKit

enum AvatarSize: Sendable {
    case small
    case medium
    case large

    var diameter: CGFloat {
        switch self {
        case .small: 44
        case .medium: 88
        case .large: 140
        }
    }

    var glyphSize: CGFloat {
        switch self {
        case .small: 22
        case .medium: 44
        case .large: 64
        }
    }
}

struct AvatarView: View {
    let spec: AvatarRenderSpec

    var size: AvatarSize = .large

    var showsNameAndTitle: Bool = true

    var tintOverride: Color?

    var body: some View {
        VStack(spacing: size == .small ? 4 : 10) {
            avatarCircle
            if showsNameAndTitle {
                nameAndTitle
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var avatarCircle: some View {
        // Stock presets render in a squircle frame; custom uploaded photos and the
        // default placeholder keep the original circular frame.
        let isStockPreset = spec.customAvatarImageData == nil && spec.preset != nil
        let squircleRadius = size.diameter * 0.22

        return ZStack {
            // Background fill sits behind the avatar content.
            if isStockPreset {
                RoundedRectangle(cornerRadius: squircleRadius, style: .continuous)
                    .fill(classGradient)
                    .frame(width: size.diameter, height: size.diameter)
            } else {
                Circle()
                    .fill(classGradient)
                    .frame(width: size.diameter, height: size.diameter)
            }

            if let customData = spec.customAvatarImageData, let uiImage = UIImage(data: customData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.diameter, height: size.diameter)
                    .clipShape(Circle())
            } else if let preset = spec.preset {
                let gear = spec.equippedAccessory.map { [$0] } ?? []
                let sprite = HeroAvatarSprites.sprite(for: preset, equippedGear: gear)
                PixelCanvasView(sprite: sprite, animated: true)
                    .frame(width: size.diameter * 0.88, height: size.diameter * 0.88)
                    .clipShape(RoundedRectangle(cornerRadius: squircleRadius * 0.88, style: .continuous))
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: size.glyphSize * 1.2, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.gold)
                    .accessibilityHidden(true)
            }

            // Border strokes draw on top so the avatar reads as framed "inside".
            if isStockPreset {
                RoundedRectangle(cornerRadius: squircleRadius, style: .continuous)
                    .strokeBorder(
                        Color.gold.opacity(0.75),
                        lineWidth: max(1.0, size.diameter * 0.018)
                    )
                    .frame(width: size.diameter, height: size.diameter)
            } else {
                Circle()
                    .strokeBorder(
                        Color.gold.opacity(0.75),
                        lineWidth: max(1.5, size.diameter * 0.025)
                    )
                    .frame(width: size.diameter, height: size.diameter)
            }
        }
        .frame(width: size.diameter, height: size.diameter)
    }

    private var nameAndTitle: some View {
        VStack(spacing: 2) {
            Text(spec.displayName)
                .font(nameFont)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(spec.levelTitle)
                .font(titleFont)
                .foregroundStyle(Color.gold)
        }
    }

    private var nameFont: Font {
        switch size {
        case .small: .subheadline.weight(.semibold)
        case .medium: .title3.bold()
        case .large: .title2.bold()
        }
    }

    private var titleFont: Font {
        switch size {
        case .small: .caption2
        case .medium: .caption.weight(.semibold)
        case .large: .subheadline.weight(.semibold)
        }
    }

    private var classGradient: LinearGradient {
        let base = tintOverride ?? classColor
        return LinearGradient(
            colors: [
                base.opacity(0.40),
                base.opacity(0.22),
                Color.white.opacity(0.10)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var classColor: Color {
        guard let cls = spec.avatarClass else {
            return spec.role.isParent ? Color.orange : Color.blue
        }
        switch cls {
        case .knight: return Color.blue
        case .mage: return Color.purple
        case .rogue: return Color.green
        case .guardian: return Color.teal
        case .healer: return Color.pink
        }
    }

    private var accessibilityLabel: String {
        var parts: [String] = [
            spec.effectiveClassDisplay,
            spec.displayName,
            spec.levelTitle
        ]
        if let equipped = spec.equippedAccessory {
            parts.append("equipped accessory \(equipped)")
        }
        return parts.joined(separator: ", ")
    }
}
