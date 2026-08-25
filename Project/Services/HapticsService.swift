//
//  HapticsService.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import UIKit

/// Centralized haptics facade wrapping UIFeedbackGenerator.
/// All feedback loops route through here so the app never produces
/// conflicting haptic patterns from independent call sites.
@MainActor
enum HapticsService {
    /// Quest approval, goal reached, trophy unlock.
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Tap on a tappable tile, bucket selection, toggle state change.
    static func rigid() {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    /// Verification rejection, error state, overdue chore.
    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    /// Light tap feedback for button presses, goal creation, and general UI interactions.
    static func lightImpact() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
