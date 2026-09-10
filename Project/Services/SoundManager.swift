//
//  SoundManager.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import AudioToolbox
import SwiftUI
import UIKit

@MainActor
@Observable
final class SoundManager {
    @ObservationIgnored
    @AppStorage("celebrationSoundEnabled") private var celebrationSoundEnabled: Bool = true

    enum SoundEvent: String, CaseIterable {
        case questComplete
        case xpGain
        case levelUp
        case lootDrop
        case gemEarned
        case streakMilestone
        case dailyLogin
        case buttonTap
        case shopPurchase
        case equipItem

        var systemSoundID: SystemSoundID {
            switch self {
            case .questComplete: 1004
            case .xpGain: 1057
            case .levelUp: 1322
            case .lootDrop: 1315
            case .gemEarned: 1054
            case .streakMilestone: 1322
            case .dailyLogin: 1315
            case .buttonTap: 1104
            case .shopPurchase: 1025
            case .equipItem: 1057
            }
        }
    }

    /// Future enhancement: Slight pitch shift ±5% on repetitive sounds using AVAudioPlayer
    func play(_ event: SoundEvent) {
        switch event {
        case .questComplete, .levelUp, .lootDrop, .streakMilestone, .shopPurchase:
            HapticsService.success()
        case .xpGain, .gemEarned, .buttonTap:
            HapticsService.lightImpact()
        case .dailyLogin, .equipItem:
            HapticsService.mediumImpact()
        }
        // WHY sound-only gate: haptics still buzz in silent mode and background.
        if celebrationSoundEnabled {
            AudioServicesPlaySystemSound(event.systemSoundID)
        }
    }
}
