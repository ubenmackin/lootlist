//
//  StreakBadge.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import SwiftUI

private enum StreakTier {
    case none
    case spark
    case kindle
    case blaze
    case inferno
    case eternal
}

struct StreakBadge: View {
    let streak: Int
    var shields: Int = 0
    var size: BadgeSize = .medium

    private var tier: StreakTier {
        switch streak {
        case 0: .none
        case 1 ... 2: .spark
        case 3 ... 6: .kindle
        case 7 ... 13: .blaze
        case 14 ... 29: .inferno
        default: .eternal
        }
    }

    private var active: Bool {
        streak >= 1
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.016)) { context in
            let date = context.date.timeIntervalSinceReferenceDate

            HStack(spacing: size.spacing) {
                flameGlyph(elapsed: date)
                Text(countText)
                    .font(size.valueFont)
                    .monospacedDigit()
                    .foregroundStyle(active ? Color.primary : Color.secondary)

                if shields > 0, tier == .eternal {
                    Text("🛡️\(shields)")
                        .font(size.valueFont)
                }
            }
            .padding(.horizontal, size.hPadding)
            .padding(.vertical, size.vPadding)
            .background(badgeBackground(elapsed: date))
            .overlay(badgeBorder(elapsed: date))
            .opacity(active ? 1.0 : 0.60)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
        }
    }

    private func flameGlyph(elapsed: TimeInterval) -> some View {
        ZStack {
            if tier == .inferno {
                EmberParticlesView(elapsed: elapsed)
            }

            Image(systemName: "flame.fill")
                .font(.system(size: glyphSize(elapsed: elapsed), weight: .bold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(flameGradient)
                .shadow(color: shadowColor, radius: shadowRadius(elapsed: elapsed))
                .rotationEffect(.degrees(rotationAngle(elapsed: elapsed)), anchor: .bottom)
        }
    }

    private func glyphSize(elapsed: TimeInterval) -> CGFloat {
        var base = size.glyphSize
        if tier == .blaze || tier == .inferno || tier == .eternal {
            base += 2
        }
        if tier == .eternal {
            let pulse = sin(elapsed * 3.5)
            base += CGFloat(pulse) * 1.5
        }
        return base
    }

    private var flameGradient: LinearGradient {
        switch tier {
        case .none:
            LinearGradient(
                colors: [Color.secondary, Color.secondary.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
        case .spark:
            LinearGradient(
                colors: [Color(DesignSystemConstants.Colors.dangerRed), Color(DesignSystemConstants.Colors.pendingAmber)],
                startPoint: .top,
                endPoint: .bottom
            )
        case .kindle:
            LinearGradient(
                colors: [Color(DesignSystemConstants.Colors.pendingAmber), Color(DesignSystemConstants.Colors.dangerRed)],
                startPoint: .top,
                endPoint: .bottom
            )
        case .blaze:
            LinearGradient(
                colors: [Color(DesignSystemConstants.Colors.dangerRed), Color(DesignSystemConstants.Colors.pendingAmber)],
                startPoint: .top,
                endPoint: .bottom
            )
        case .inferno:
            LinearGradient(
                colors: [
                    Color(DesignSystemConstants.Colors.accentBlue),
                    Color(DesignSystemConstants.Colors.pendingAmber),
                    Color.gold
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        case .eternal:
            // White core is a structural flame highlight, not a theme token.
            LinearGradient(
                colors: [Color.white, Color(DesignSystemConstants.Colors.accentBlue), Color(DesignSystemConstants.Colors.pendingAmber)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var shadowColor: Color {
        if tier == .blaze {
            return Color(DesignSystemConstants.Colors.dangerRed).opacity(0.8)
        }
        if tier == .eternal {
            return Color.white.opacity(0.8)
        }
        return .clear
    }

    private func shadowRadius(elapsed: TimeInterval) -> CGFloat {
        if tier == .blaze {
            return 3 + CGFloat(sin(elapsed * 2.5)) * 2
        }
        if tier == .eternal {
            return 4 + CGFloat(sin(elapsed * 3.5)) * 2
        }
        return 0
    }

    private func rotationAngle(elapsed: TimeInterval) -> Double {
        switch tier {
        case .none, .spark: 0
        case .kindle: sin(elapsed * 2.0) * 5.0
        case .blaze: sin(elapsed * 2.5) * 8.0
        case .inferno: sin(elapsed * 3.0) * 10.0
        case .eternal: sin(elapsed * 3.5) * 12.0
        }
    }

    @ViewBuilder
    private func badgeBackground(elapsed: TimeInterval) -> some View {
        if !active {
            Capsule().fill(Color.secondary.opacity(0.12))
        } else {
            ZStack {
                switch tier {
                case .none, .spark:
                    Capsule().fill(Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.14))
                case .kindle:
                    Capsule().fill(Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.20))
                case .blaze:
                    Capsule().fill(Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.25))
                case .inferno:
                    Capsule().fill(Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.30))
                case .eternal:
                    Capsule().fill(Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.35))
                    Capsule().fill(
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.3 * (sin(elapsed * 4) + 1) / 2), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func badgeBorder(elapsed _: TimeInterval) -> some View {
        if !active {
            Capsule().strokeBorder(Color.secondary.opacity(0.20), lineWidth: 1)
        } else {
            switch tier {
            case .none, .spark:
                Capsule().strokeBorder(Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.55), lineWidth: 1)
            case .kindle:
                Capsule().strokeBorder(Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.65), lineWidth: 1)
            case .blaze:
                Capsule().strokeBorder(Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.80), lineWidth: 1.5)
            case .inferno:
                Capsule().strokeBorder(Color(DesignSystemConstants.Colors.pendingAmber).opacity(0.90), lineWidth: 1.5)
            case .eternal:
                Capsule().strokeBorder(Color(DesignSystemConstants.Colors.pendingAmber), lineWidth: 2)
            }
        }
    }

    private var countText: String {
        streak > 0 ? "\(streak)" : "—"
    }

    private var accessibilityLabel: String {
        let tierName = String(describing: tier)
        return streak > 0
            ? "Combo streak \(streak) days, \(tierName) tier"
            : "No active streak, none tier"
    }
}

// MARK: - Ember Particles

struct EmberParticlesView: View {
    let elapsed: TimeInterval

    var body: some View {
        ZStack {
            ForEach(0 ..< 3) { particleIndex in
                Circle()
                    .fill(Color(DesignSystemConstants.Colors.pendingAmber))
                    .frame(width: 2, height: 2)
                    .offset(x: xOffset(for: particleIndex, elapsed: elapsed), y: offset(for: particleIndex, elapsed: elapsed))
                    .opacity(opacity(for: particleIndex, elapsed: elapsed))
            }
        }
    }

    private func offset(for particleIndex: Int, elapsed: TimeInterval) -> CGFloat {
        let phase = Double(particleIndex) * 2.0
        let time = elapsed + phase
        let progress = time.truncatingRemainder(dividingBy: 2.0)
        return -CGFloat(progress * 15.0)
    }

    private func xOffset(for particleIndex: Int, elapsed: TimeInterval) -> CGFloat {
        let phase = Double(particleIndex) * 1.5
        return CGFloat(sin(elapsed * 3 + phase) * 4)
    }

    private func opacity(for particleIndex: Int, elapsed: TimeInterval) -> Double {
        let phase = Double(particleIndex) * 2.0
        let time = elapsed + phase
        let progress = time.truncatingRemainder(dividingBy: 2.0) / 2.0
        return 1.0 - progress
    }
}
