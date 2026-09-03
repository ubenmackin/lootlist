//
//  DesignSystemConstants.swift
//  LootList
//
//  Created by Ben Mackin on 8/13/26.
//

import CoreGraphics
import Foundation

enum DesignSystemConstants {
    /// Asset Catalog color names — every screen supports light AND dark mode
    /// through these semantic tokens. Views use them via `Color(name)`.
    enum Colors {
        /// Light #F5F6F8 / Dark #1C1C1E — main screen background.
        static let background = "background"

        /// Light #FFFFFF / Dark #2C2C2E — card and sheet surfaces.
        static let cardSurface = "cardSurface"

        /// Light #34C759 / Dark #30D158 — positive actions, amounts, progress.
        static let primaryGreen = "primaryGreen"

        /// Light #007AFF / Dark #0A84FF — links, interactive accents.
        static let accentBlue = "accentBlue"

        /// Light #FF9500 / Dark #FF9F0A — pending, needs attention.
        static let pendingAmber = "pendingAmber"

        /// Light #FF3B30 / Dark #FF453A — destructive actions, overdue.
        static let dangerRed = "dangerRed"

        /// Light #D9A834 / Dark #E8C05C asset-backed semantic gold token.
        static let gold = "gold"

        // Rarity palette semantic asset tokens for QuestRarity.
        static let rarityCommon = "rarityCommon"
        static let rarityRare = "rarityRare"
        static let rarityEpic = "rarityEpic"
        static let rarityLegendary = "rarityLegendary"

        // Journey map art palette semantic tokens owned by JourneyZone.ZonePalette.
        static let journeyStartingMeadowPath = "journeyStartingMeadowPath"
        static let journeyStartingMeadowGround = "journeyStartingMeadowGround"
        static let journeyStartingMeadowAccent = "journeyStartingMeadowAccent"
        static let journeyStartingMeadowSkyTop = "journeyStartingMeadowSkyTop"
        static let journeyStartingMeadowSkyBottom = "journeyStartingMeadowSkyBottom"
        static let journeyDenseForestPath = "journeyDenseForestPath"
        static let journeyDenseForestGround = "journeyDenseForestGround"
        static let journeyDenseForestAccent = "journeyDenseForestAccent"
        static let journeyDenseForestSkyTop = "journeyDenseForestSkyTop"
        static let journeyDenseForestSkyBottom = "journeyDenseForestSkyBottom"
        static let journeyMountainPassPath = "journeyMountainPassPath"
        static let journeyMountainPassGround = "journeyMountainPassGround"
        static let journeyMountainPassAccent = "journeyMountainPassAccent"
        static let journeyMountainPassSkyTop = "journeyMountainPassSkyTop"
        static let journeyMountainPassSkyBottom = "journeyMountainPassSkyBottom"
        static let journeyDragonsReachPath = "journeyDragonsReachPath"
        static let journeyDragonsReachGround = "journeyDragonsReachGround"
        static let journeyDragonsReachAccent = "journeyDragonsReachAccent"
        static let journeyDragonsReachSkyTop = "journeyDragonsReachSkyTop"
        static let journeyDragonsReachSkyBottom = "journeyDragonsReachSkyBottom"
        static let journeyEternalRealmPath = "journeyEternalRealmPath"
        static let journeyEternalRealmGround = "journeyEternalRealmGround"
        static let journeyEternalRealmAccent = "journeyEternalRealmAccent"
        static let journeyEternalRealmSkyTop = "journeyEternalRealmSkyTop"
        static let journeyEternalRealmSkyBottom = "journeyEternalRealmSkyBottom"

        // Journey zone decoration semantic tokens — light/dark via asset catalog.
        static let journeyStartingMeadowTerrain = "journeyStartingMeadowTerrain"
        static let journeyDenseForestTerrain = "journeyDenseForestTerrain"
        static let journeyMountainPassTerrain = "journeyMountainPassTerrain"
        static let journeyDragonsReachTerrain = "journeyDragonsReachTerrain"
        static let journeyEternalRealmTerrain = "journeyEternalRealmTerrain"
        static let journeyStartingMeadowFlowerPink = "journeyStartingMeadowFlowerPink"
        static let journeyDenseForestTree = "journeyDenseForestTree"
        static let journeyDenseForestMist = "journeyDenseForestMist"
        static let journeyMountainPassRock = "journeyMountainPassRock"
        static let journeyDragonsReachSpire = "journeyDragonsReachSpire"
        static let journeyDragonsReachEmberCore = "journeyDragonsReachEmberCore"
        static let journeyDragonsReachEmberOuter = "journeyDragonsReachEmberOuter"
        static let journeyEternalRealmIslandTop = "journeyEternalRealmIslandTop"
        static let journeyEternalRealmIslandBottom = "journeyEternalRealmIslandBottom"
        static let journeyFrostedScrim = "journeyFrostedScrim"
        static let journeyGoldEmboss = "journeyGoldEmboss"
        static let journeyStoneNode = "journeyStoneNode"
    }

    enum CornerRadius {
        static let small: CGFloat = 12
        static let button: CGFloat = 14
        static let card: CGFloat = 16
        static let header: CGFloat = 20
        static let modal: CGFloat = 24
    }

    enum Padding {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let standard: CGFloat = 16
        static let large: CGFloat = 20
        static let xlarge: CGFloat = 24
    }

    enum AvatarSize {
        static let small: CGFloat = 50
        static let medium: CGFloat = 64
        static let large: CGFloat = 120
    }

    enum AnimationDuration {
        static let progressFill: Double = 0.45
        static let toggleFeedbackNanos: UInt64 = 2_000_000_000
        static let notificationTriggerInterval: TimeInterval = 1.0
    }

    enum Celebration {
        static let confettiParticleCount: Int = 50
        static let confettiLifetime: TimeInterval = 5.0
        static let initialScale: Double = 0.3
    }

    // WHY: 1040 caps reader width + inspector 320 keeps ViewThatFitsSplit in sync, collapsing split to compact when constrained width no longer fits.
    enum Layout {
        static let maxContentWidth: CGFloat = 1040
        static let maxBannerWidth: CGFloat = 640
        static let iPadTableThreshold: CGFloat = 700
        static let inspectorWidth: CGFloat = 320
    }
}
