//
//  MascotSprites.swift
//  LootList
//
//  Created by Ben Mackin on 8/17/26.
//

import SwiftUI

@MainActor
struct MascotSpriteRenderer {
    // MARK: - Sprite Provider

    static let canvasSize: Int = 64

    /// Generates a composite `PixelSpriteData` for a given mascot companion, state, and frame index.
    static func sprite(for companion: MascotCompanion, state: MascotState, frameIndex: Int) -> PixelSpriteData {
        let matrix = frame(for: companion, state: state, frameIndex: frameIndex)
        let pal = palette(for: companion)
        let layerID = "mascot_\(companion.rawValue)_\(stateKey(state))_\(frameIndex)"

        return PixelSpriteData(
            width: canvasSize,
            height: canvasSize,
            layers: [
                PixelLayer(id: layerID, matrix: matrix, palette: pal, zIndex: 0)
            ]
        )
    }

    // MARK: - Internal Providers

    static func frame(for companion: MascotCompanion, state: MascotState, frameIndex: Int) -> [String] {
        let isHappy = (state == .celebrating || state == .bonusClaimed)
        let isAltFrame = (frameIndex % 2 == 1)

        switch companion {
        case .owl:
            if isHappy {
                return isAltFrame ? owlHappyAlt : owlHappy
            } else {
                return isAltFrame ? owlIdleAlt : owlIdle
            }
        case .dragon:
            if isHappy {
                return isAltFrame ? dragonHappyAlt : dragonHappy
            } else {
                return isAltFrame ? dragonIdleAlt : dragonIdle
            }
        case .fairy:
            if isHappy {
                return isAltFrame ? fairyHappyAlt : fairyHappy
            } else {
                return isAltFrame ? fairyIdleAlt : fairyIdle
            }
        case .fox:
            if isHappy {
                return isAltFrame ? foxHappyAlt : foxHappy
            } else {
                return isAltFrame ? foxIdleAlt : foxIdle
            }
        case .cat:
            if isHappy {
                return isAltFrame ? catHappyAlt : catHappy
            } else {
                return isAltFrame ? catIdleAlt : catIdle
            }
        }
    }

    static func palette(for companion: MascotCompanion) -> [Character: Color] {
        switch companion {
        case .owl:
            [
                ".": .clear,
                "D": color(hex: 0x3B2412),
                "B": color(hex: 0x8A5A33),
                "S": color(hex: 0x5F3D20),
                "H": color(hex: 0xB98A5F),
                "C": color(hex: 0xF2E3C6),
                "Y": color(hex: 0xF7C948),
                "P": color(hex: 0x211A15),
                "W": .white,
                "O": color(hex: 0xE8862E)
            ]
        case .dragon:
            [
                ".": .clear,
                "D": color(hex: 0x3A0D0D),
                "R": color(hex: 0xC62828),
                "S": color(hex: 0x8E1B1B),
                "H": color(hex: 0xEF5350),
                "O": color(hex: 0xE8732A),
                "Y": color(hex: 0xF9D423),
                "W": .white,
                "P": color(hex: 0x1A1A1A)
            ]
        case .fairy:
            [
                ".": .clear,
                "D": color(hex: 0x2D1B3D),
                "P": color(hex: 0xEC6FA8),
                "S": color(hex: 0x9B4D9E),
                "H": color(hex: 0xF9A8D4),
                "F": color(hex: 0xFBD8C4),
                "Y": color(hex: 0xF5D76E),
                "B": color(hex: 0x3B82F6),
                "W": .white,
                "K": color(hex: 0x1E3A8A),
                "G": color(hex: 0xFDE047)
            ]
        case .fox:
            [
                ".": Color.clear,
                "D": Color.black,
                "W": Color(red: 0.973, green: 0.980, blue: 0.988),
                "O": Color(red: 0.910, green: 0.451, blue: 0.165),
                "o": color(hex: 0xC2410C),
                "H": color(hex: 0xFED7AA),
                "G": Color(red: 0.133, green: 0.773, blue: 0.369),
                "g": color(hex: 0x166534),
                "B": Color.black,
                "F": color(hex: 0x7C2D12),
                "P": color(hex: 0x1A1A1A),
                "C": color(hex: 0xF5E6C8)
            ]
        case .cat:
            [
                ".": .clear,
                "D": color(hex: 0x2A2A2E),
                "G": color(hex: 0x9AA0A6),
                "S": color(hex: 0x6B7280),
                "H": color(hex: 0xD1D5DB),
                "C": color(hex: 0xF5E6C8),
                "W": .white,
                "P": color(hex: 0xF08C9E),
                "B": .black
            ]
        }
    }

    // MARK: - Private Helpers

    private static func color(hex: UInt32, alpha: Double = 1.0) -> Color {
        let red = Double((hex >> 16) & 0xFF) / 255.0
        let green = Double((hex >> 8) & 0xFF) / 255.0
        let blue = Double(hex & 0xFF) / 255.0
        return Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    private static func stateKey(_ state: MascotState) -> String {
        switch state {
        case .idle: "idle"
        case .inProgress: "inProgress"
        case .encouraging: "encouraging"
        case .celebrating: "celebrating"
        case .bonusClaimed: "bonusClaimed"
        }
    }
}
