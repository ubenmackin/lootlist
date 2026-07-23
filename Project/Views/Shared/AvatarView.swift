import CloudKit
import SwiftUI

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

    var accessorySize: CGFloat {
        switch self {
        case .small: 12
        case .medium: 22
        case .large: 32
        }
    }

    var accessoryPadding: CGFloat {
        switch self {
        case .small: 2
        case .medium: 4
        case .large: 6
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
        ZStack {
            Circle()
                .fill(classGradient)
                .frame(width: size.diameter, height: size.diameter)
                .overlay(
                    Circle()
                        .strokeBorder(
                            Color.gold.opacity(0.75),
                            lineWidth: max(1.5, size.diameter * 0.025)
                        )
                )

            if UIImage(named: spec.preset.assetName) != nil {
                Image(spec.preset.assetName)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.diameter, height: size.diameter)
                    .offset(y: size.diameter * 0.07)
                    .clipShape(Circle())
            } else {
                Image(systemName: spec.preset.iconSystemName)
                    .font(.system(size: size.glyphSize, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.gold)
                    .symbolEffect(.pulse, options: .repeating)
                    .accessibilityHidden(true)
            }

            accessoryOverlay
        }
        .frame(width: size.diameter, height: size.diameter)
    }

    @ViewBuilder
    private var accessoryOverlay: some View {
        if let glyph = effectiveAccessoryGlyph {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.35))
                    .frame(width: size.accessorySize + size.accessoryPadding * 2,
                           height: size.accessorySize + size.accessoryPadding * 2)
                Image(systemName: glyph)
                    .font(.system(size: size.accessorySize, weight: .bold))
                    .foregroundStyle(Color.gold)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
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

    private var effectiveAccessoryGlyph: String? {
        if let equipped = spec.equippedAccessory,
           let glyph = AvatarService.accessoryGlyph(for: equipped)
        {
            return glyph
        }
        return spec.preset.accessoryIconSystemName
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
        switch spec.avatarClass {
        case .knight: Color.blue
        case .mage: Color.purple
        case .rogue: Color.green
        case .guardian: Color.teal
        case .healer: Color.pink
        }
    }

    private var accessibilityLabel: String {
        var parts: [String] = [
            "\(spec.preset.displayName) \(spec.avatarClass.displayName)",
            spec.displayName,
            spec.levelTitle
        ]
        if let equipped = spec.equippedAccessory {
            parts.append("equipped accessory \(equipped)")
        }
        return parts.joined(separator: ", ")
    }
}
