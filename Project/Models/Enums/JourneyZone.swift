//
//  JourneyZone.swift
//  LootList
//
//  Created by Ben Mackin on 8/22/26.
//

import SwiftUI

// MARK: - Journey Zone

/// Themed zones along the hero's Journey Map, each spanning a range of levels.
/// Purely cosmetic — driven entirely by `Profile.level`.
enum JourneyZone: Int, CaseIterable, Sendable {
    case startingMeadow = 0
    case denseForest = 1
    case mountainPass = 2
    case dragonsReach = 3
    case eternalRealm = 4

    // MARK: - Display Properties

    var displayName: String {
        switch self {
        case .startingMeadow: "The Starting Meadow"
        case .denseForest: "The Dense Forest"
        case .mountainPass: "The Mountain Pass"
        case .dragonsReach: "Dragon's Reach"
        case .eternalRealm: "The Eternal Realm"
        }
    }

    var shortName: String {
        switch self {
        case .startingMeadow: "Meadow"
        case .denseForest: "Forest"
        case .mountainPass: "Mountains"
        case .dragonsReach: "Dragon's Reach"
        case .eternalRealm: "Eternal Realm"
        }
    }

    var flavorText: String {
        switch self {
        case .startingMeadow:
            "A gentle sunlit meadow where all journeys begin. The path ahead is full of promise."
        case .denseForest:
            "Ancient towering canopies filter emerald light. Secrets and challenges dwell here."
        case .mountainPass:
            "Frosty crags and soaring peaks test your resolve. Only the steadfast reach the top."
        case .dragonsReach:
            "Volcanic stone and smoldering embers mark the domain of legends and great deeds."
        case .eternalRealm:
            "Beyond the mortal world, starlight and cosmic aurora guide the ultimate heroes."
        }
    }

    var iconSystemName: String {
        switch self {
        case .startingMeadow: "leaf.fill"
        case .denseForest: "tree.fill"
        case .mountainPass: "mountain.2.fill"
        case .dragonsReach: "flame.fill"
        case .eternalRealm: "sparkles"
        }
    }

    // MARK: - Level Ranges

    /// The level range this zone covers. `eternalRealm` is open-ended.
    var levelRange: ClosedRange<Int> {
        switch self {
        case .startingMeadow: 1 ... 5
        case .denseForest: 6 ... 10
        case .mountainPass: 11 ... 15
        case .dragonsReach: 16 ... 20
        case .eternalRealm: 21 ... Int.max
        }
    }

    /// Number of milestone dots to render in this zone on the map.
    /// The Eternal Realm caps at 10 visible milestones (levels 21–30).
    var milestoneCount: Int {
        switch self {
        case .eternalRealm: JourneyZone.eternalRealmDisplayCap
        default: levelRange.count
        }
    }

    /// The first level number in this zone.
    var startLevel: Int {
        levelRange.lowerBound
    }

    /// Display cap for the unbounded Eternal Realm zone.
    static let eternalRealmDisplayCap: Int = 10

    // MARK: - Zone Lookup

    /// Returns the zone for a given hero level.
    static func zone(forLevel level: Int) -> JourneyZone {
        for candidate in allCases where candidate.levelRange.contains(level) {
            return candidate
        }
        return .eternalRealm
    }

    // MARK: - Zone Palette

    /// Color palette for rendering this zone's elements, accents, and banners.
    var palette: ZonePalette {
        switch self {
        case .startingMeadow:
            ZonePalette(
                pathColor: Color(red: 0.85, green: 0.74, blue: 0.48),
                groundColor: Color(red: 0.38, green: 0.68, blue: 0.28),
                accentColor: Color(red: 0.98, green: 0.84, blue: 0.22),
                skyTop: Color(red: 0.46, green: 0.76, blue: 0.96),
                skyBottom: Color(red: 0.78, green: 0.92, blue: 0.62)
            )
        case .denseForest:
            ZonePalette(
                pathColor: Color(red: 0.58, green: 0.48, blue: 0.32),
                groundColor: Color(red: 0.16, green: 0.38, blue: 0.20),
                accentColor: Color(red: 0.34, green: 0.78, blue: 0.42),
                skyTop: Color(red: 0.22, green: 0.42, blue: 0.34),
                skyBottom: Color(red: 0.38, green: 0.62, blue: 0.38)
            )
        case .mountainPass:
            ZonePalette(
                pathColor: Color(red: 0.70, green: 0.68, blue: 0.64),
                groundColor: Color(red: 0.48, green: 0.50, blue: 0.54),
                accentColor: Color(red: 0.55, green: 0.82, blue: 0.98),
                skyTop: Color(red: 0.32, green: 0.42, blue: 0.58),
                skyBottom: Color(red: 0.64, green: 0.72, blue: 0.82)
            )
        case .dragonsReach:
            ZonePalette(
                pathColor: Color(red: 0.52, green: 0.26, blue: 0.16),
                groundColor: Color(red: 0.26, green: 0.10, blue: 0.08),
                accentColor: Color(red: 0.98, green: 0.48, blue: 0.14),
                skyTop: Color(red: 0.38, green: 0.12, blue: 0.08),
                skyBottom: Color(red: 0.62, green: 0.22, blue: 0.10)
            )
        case .eternalRealm:
            ZonePalette(
                pathColor: Color(red: 0.75, green: 0.65, blue: 0.95),
                groundColor: Color(red: 0.14, green: 0.06, blue: 0.26),
                accentColor: Color(red: 0.82, green: 0.68, blue: 1.0),
                skyTop: Color(red: 0.12, green: 0.05, blue: 0.28),
                skyBottom: Color(red: 0.28, green: 0.14, blue: 0.54)
            )
        }
    }

    // MARK: - Continuous World Gradients

    /// Seamless panoramic sky gradient spanning the entire world map from Meadow to Eternal Realm.
    static var panoramicSkyGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Color(red: 0.46, green: 0.76, blue: 0.96), location: 0.0),
                .init(color: Color(red: 0.42, green: 0.72, blue: 0.90), location: 0.15),
                .init(color: Color(red: 0.22, green: 0.48, blue: 0.40), location: 0.28),
                .init(color: Color(red: 0.18, green: 0.38, blue: 0.32), location: 0.38),
                .init(color: Color(red: 0.32, green: 0.44, blue: 0.60), location: 0.48),
                .init(color: Color(red: 0.28, green: 0.36, blue: 0.52), location: 0.58),
                .init(color: Color(red: 0.42, green: 0.14, blue: 0.10), location: 0.68),
                .init(color: Color(red: 0.28, green: 0.08, blue: 0.08), location: 0.78),
                .init(color: Color(red: 0.16, green: 0.06, blue: 0.30), location: 0.88),
                .init(color: Color(red: 0.08, green: 0.04, blue: 0.18), location: 1.0)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    /// Seamless panoramic ground gradient spanning rolling hills from Meadow to Eternal Realm.
    static var panoramicGroundGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Color(red: 0.38, green: 0.68, blue: 0.28), location: 0.0),
                .init(color: Color(red: 0.32, green: 0.60, blue: 0.24), location: 0.15),
                .init(color: Color(red: 0.16, green: 0.38, blue: 0.20), location: 0.32),
                .init(color: Color(red: 0.48, green: 0.50, blue: 0.54), location: 0.52),
                .init(color: Color(red: 0.26, green: 0.10, blue: 0.08), location: 0.72),
                .init(color: Color(red: 0.14, green: 0.06, blue: 0.26), location: 0.90),
                .init(color: Color(red: 0.10, green: 0.04, blue: 0.18), location: 1.0)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

// MARK: - Zone Palette

/// Color set for rendering a single journey zone.
struct ZonePalette: Sendable, Equatable {
    let pathColor: Color
    let groundColor: Color
    let accentColor: Color
    let skyTop: Color
    let skyBottom: Color

    var skyGradient: LinearGradient {
        LinearGradient(
            colors: [skyTop, skyBottom],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
