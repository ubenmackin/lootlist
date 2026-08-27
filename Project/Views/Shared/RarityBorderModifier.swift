//
//  RarityBorderModifier.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import SwiftUI

struct RarityBorderModifier: ViewModifier {
    let rarity: QuestRarity

    func body(content: Content) -> some View {
        content
            .overlay(
                ZStack(alignment: .topTrailing) {
                    switch rarity {
                    case .common:
                        RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.button)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)

                    case .rare:
                        RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.button)
                            .stroke(Color(DesignSystemConstants.Colors.accentBlue).opacity(0.5), lineWidth: 1.5)
                        rarityBadge

                    case .epic:
                        TimelineView(.animation) { timeline in
                            let angle = timeline.date.timeIntervalSinceReferenceDate * 180
                            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.button)
                                .strokeBorder(
                                    AngularGradient(
                                        colors: [
                                            Color(DesignSystemConstants.Colors.accentBlue).opacity(0.3),
                                            Color(DesignSystemConstants.Colors.accentBlue).opacity(0.8),
                                            Color(DesignSystemConstants.Colors.accentBlue).opacity(0.3)
                                        ],
                                        center: .center,
                                        angle: .degrees(angle)
                                    ),
                                    lineWidth: 2
                                )
                                .shadow(color: Color(DesignSystemConstants.Colors.accentBlue).opacity(0.4), radius: 3)
                        }
                        rarityBadge

                    case .legendary:
                        TimelineView(.animation) { timeline in
                            let pulse = (sin(timeline.date.timeIntervalSinceReferenceDate * 2) + 1) / 2
                            RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.button)
                                .strokeBorder(Color.gold, lineWidth: 2)
                                .shadow(color: Color.gold.opacity(0.4 + (0.4 * pulse)), radius: 4 + (2 * pulse))

                            Canvas { context, size in
                                let time = timeline.date.timeIntervalSinceReferenceDate
                                let particleCount = 12

                                for particleIndex in 0 ..< particleCount {
                                    let seed = Double(particleIndex * 137)
                                    let speed = 0.5 + (Double(particleIndex % 5) * 0.1)

                                    let perimeter = (size.width + size.height) * 2
                                    let currentPos = fmod(time * 50 * speed + seed, perimeter)

                                    var coordX: CGFloat = 0
                                    var coordY: CGFloat = 0

                                    if currentPos < size.width {
                                        coordX = currentPos
                                        coordY = 0
                                    } else if currentPos < size.width + size.height {
                                        coordX = size.width
                                        coordY = currentPos - size.width
                                    } else if currentPos < size.width * 2 + size.height {
                                        coordX = size.width - (currentPos - size.width - size.height)
                                        coordY = size.height
                                    } else {
                                        coordX = 0
                                        coordY = size.height - (currentPos - size.width * 2 - size.height)
                                    }

                                    let alpha = (sin(time * 3 + seed) + 1) / 2
                                    context.opacity = alpha * 0.8

                                    let rect = CGRect(x: coordX - 1.5, y: coordY - 1.5, width: 3, height: 3)
                                    var path = Path()
                                    path.addEllipse(in: rect)
                                    context.fill(path, with: .color(Color.gold))
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: DesignSystemConstants.CornerRadius.button))
                        }
                        rarityBadge
                    }
                }
            )
    }

    @ViewBuilder
    private var rarityBadge: some View {
        if rarity != .common {
            HStack(spacing: 4) {
                Image(systemName: rarity.iconSystemName)
                    .font(.system(size: 10, weight: .bold))
                Text(rarity.rawValue)
                    .font(.system(size: 10, weight: .bold))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(rarity.color.opacity(0.15))
            .foregroundStyle(rarity.color)
            .clipShape(Capsule())
            .padding([.top, .trailing], 8)
        }
    }
}

extension View {
    func rarityBorder(_ rarity: QuestRarity) -> some View {
        self.modifier(RarityBorderModifier(rarity: rarity))
    }
}
