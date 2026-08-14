//
//  DesignSystemConstants.swift
//  LootList
//
//  Created by Ben Mackin on 8/13/26.
//

import CoreGraphics
import Foundation

enum DesignSystemConstants {
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
