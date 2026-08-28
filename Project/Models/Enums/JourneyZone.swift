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

    /// Color palette for rendering this zone's elements and accents.
    var palette: ZonePalette {
        switch self {
        case .startingMeadow:
            ZonePalette(
                pathColor: Color(DesignSystemConstants.Colors.journeyStartingMeadowPath),
                groundColor: Color(DesignSystemConstants.Colors.journeyStartingMeadowGround),
                accentColor: Color(DesignSystemConstants.Colors.journeyStartingMeadowAccent),
                skyTop: Color(DesignSystemConstants.Colors.journeyStartingMeadowSkyTop),
                skyBottom: Color(DesignSystemConstants.Colors.journeyStartingMeadowSkyBottom)
            )
        case .denseForest:
            ZonePalette(
                pathColor: Color(DesignSystemConstants.Colors.journeyDenseForestPath),
                groundColor: Color(DesignSystemConstants.Colors.journeyDenseForestGround),
                accentColor: Color(DesignSystemConstants.Colors.journeyDenseForestAccent),
                skyTop: Color(DesignSystemConstants.Colors.journeyDenseForestSkyTop),
                skyBottom: Color(DesignSystemConstants.Colors.journeyDenseForestSkyBottom)
            )
        case .mountainPass:
            ZonePalette(
                pathColor: Color(DesignSystemConstants.Colors.journeyMountainPassPath),
                groundColor: Color(DesignSystemConstants.Colors.journeyMountainPassGround),
                accentColor: Color(DesignSystemConstants.Colors.journeyMountainPassAccent),
                skyTop: Color(DesignSystemConstants.Colors.journeyMountainPassSkyTop),
                skyBottom: Color(DesignSystemConstants.Colors.journeyMountainPassSkyBottom)
            )
        case .dragonsReach:
            ZonePalette(
                pathColor: Color(DesignSystemConstants.Colors.journeyDragonsReachPath),
                groundColor: Color(DesignSystemConstants.Colors.journeyDragonsReachGround),
                accentColor: Color(DesignSystemConstants.Colors.journeyDragonsReachAccent),
                skyTop: Color(DesignSystemConstants.Colors.journeyDragonsReachSkyTop),
                skyBottom: Color(DesignSystemConstants.Colors.journeyDragonsReachSkyBottom)
            )
        case .eternalRealm:
            ZonePalette(
                pathColor: Color(DesignSystemConstants.Colors.journeyEternalRealmPath),
                groundColor: Color(DesignSystemConstants.Colors.journeyEternalRealmGround),
                accentColor: Color(DesignSystemConstants.Colors.journeyEternalRealmAccent),
                skyTop: Color(DesignSystemConstants.Colors.journeyEternalRealmSkyTop),
                skyBottom: Color(DesignSystemConstants.Colors.journeyEternalRealmSkyBottom)
            )
        }
    }

    // MARK: - Continuous World Gradients

    /// Seamless panoramic sky gradient spanning the entire world map.
    static var panoramicSkyGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Color(DesignSystemConstants.Colors.journeyStartingMeadowSkyTop), location: 0.0),
                .init(color: Color(DesignSystemConstants.Colors.journeyStartingMeadowSkyBottom), location: 0.15),
                .init(color: Color(DesignSystemConstants.Colors.journeyDenseForestSkyTop), location: 0.28),
                .init(color: Color(DesignSystemConstants.Colors.journeyDenseForestSkyBottom), location: 0.38),
                .init(color: Color(DesignSystemConstants.Colors.journeyMountainPassSkyTop), location: 0.48),
                .init(color: Color(DesignSystemConstants.Colors.journeyMountainPassSkyBottom), location: 0.58),
                .init(color: Color(DesignSystemConstants.Colors.journeyDragonsReachSkyTop), location: 0.68),
                .init(color: Color(DesignSystemConstants.Colors.journeyDragonsReachSkyBottom), location: 0.78),
                .init(color: Color(DesignSystemConstants.Colors.journeyEternalRealmSkyTop), location: 0.88),
                .init(color: Color(DesignSystemConstants.Colors.journeyEternalRealmSkyBottom), location: 1.0)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    /// Seamless panoramic ground gradient spanning rolling hills from Meadow to Eternal Realm.
    static var panoramicGroundGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Color(DesignSystemConstants.Colors.journeyStartingMeadowGround), location: 0.0),
                .init(color: Color(DesignSystemConstants.Colors.journeyDenseForestGround), location: 0.15),
                .init(color: Color(DesignSystemConstants.Colors.journeyDenseForestGround), location: 0.32),
                .init(color: Color(DesignSystemConstants.Colors.journeyMountainPassGround), location: 0.52),
                .init(color: Color(DesignSystemConstants.Colors.journeyDragonsReachGround), location: 0.72),
                .init(color: Color(DesignSystemConstants.Colors.journeyEternalRealmGround), location: 0.90),
                .init(color: Color(DesignSystemConstants.Colors.journeyEternalRealmGround), location: 1.0)
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
