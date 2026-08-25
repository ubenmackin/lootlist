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
}
