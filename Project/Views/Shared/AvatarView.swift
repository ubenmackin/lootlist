import SwiftUI
import CloudKit

enum AvatarSize: Sendable {
    case small
    case medium
    case large

    var diameter: CGFloat {
        switch self {
        case .small:  return 44
        case .medium: return 88
        case .large:  return 140
        }
    }

    var glyphSize: CGFloat {
        switch self {
        case .small:  return 22
        case .medium: return 44
        case .large:  return 64
        }
    }

    var accessorySize: CGFloat {
        switch self {
        case .small:  return 12
        case .medium: return 22
        case .large:  return 32
        }
    }

    var accessoryPadding: CGFloat {
        switch self {
        case .small:  return 2
        case .medium: return 4
        case .large:  return 6
        }
    }
}

struct AvatarView: View {

    let spec: AvatarRenderSpec

    var size: AvatarSize = .large

    var showsNameAndTitle: Bool = true

    var tintOverride: Color? = nil

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

            Image(systemName: spec.preset.iconSystemName)
                .font(.system(size: size.glyphSize, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.gold)
                .symbolEffect(.pulse, options: .repeating)
                .accessibilityHidden(true)

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

    @ViewBuilder
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
        case .small:  return .subheadline.weight(.semibold)
        case .medium: return .title3.bold()
        case .large:  return .title2.bold()
        }
    }

    private var titleFont: Font {
        switch size {
        case .small:  return .caption2
        case .medium: return .caption.weight(.semibold)
        case .large:  return .subheadline.weight(.semibold)
        }
    }

    private var effectiveAccessoryGlyph: String? {
        if let equipped = spec.equippedAccessory,
           let glyph = AvatarService.accessoryGlyph(for: equipped) {
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
        case .knight:    return Color.blue
        case .mage:      return Color.purple
        case .rogue:     return Color.green
        case .guardian:  return Color.teal
        case .healer:    return Color.pink
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
