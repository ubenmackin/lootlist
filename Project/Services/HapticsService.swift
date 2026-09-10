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
    private static let notificationGenerator = UINotificationFeedbackGenerator()
    private static let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
    private static let rigidGenerator = UIImpactFeedbackGenerator(style: .rigid)
    private static var lastSuccess = Date.distantPast
    private static let coalesceInterval: TimeInterval = 0.5

    /// Quest approval, goal reached, trophy unlock.
    static func success() {
        // WHY coalesce: helper and overlay fire together on final completion.
        let now = Date()
        guard now.timeIntervalSince(lastSuccess) >= coalesceInterval else { return }
        lastSuccess = now
        notificationGenerator.notificationOccurred(.success)
        notificationGenerator.prepare()
    }

    /// Tap on a tappable tile, bucket selection, toggle state change.
    static func rigid() {
        rigidGenerator.impactOccurred()
        rigidGenerator.prepare()
    }

    /// Verification rejection, error state, overdue chore.
    static func warning() {
        notificationGenerator.notificationOccurred(.warning)
        notificationGenerator.prepare()
    }

    /// Light tap feedback for button presses, goal creation, and general UI interactions.
    static func lightImpact() {
        lightGenerator.impactOccurred()
        lightGenerator.prepare()
    }

    /// Medium tap for daily login and equip confirmations.
    static func mediumImpact() {
        mediumGenerator.impactOccurred()
        mediumGenerator.prepare()
    }

    /// Warms generators ahead of rapid taps.
    static func prepare() {
        notificationGenerator.prepare()
        lightGenerator.prepare()
        mediumGenerator.prepare()
        rigidGenerator.prepare()
    }
}
