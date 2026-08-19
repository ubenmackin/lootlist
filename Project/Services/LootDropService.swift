//
//  LootDropService.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import Foundation
import os
import SwiftUI

struct LootDrop: Sendable, Equatable {
    let gemAmount: Int
    let description: String
    let rarity: QuestRarity
}

@MainActor
@Observable
final class LootDropService {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "LootDrop")
    let gemService: GemService
    let toastManager: ToastManager?
    let soundManager: SoundManager?

    /// Most recent loot drop awaiting UI presentation. Cleared after overlay dismiss.
    private(set) var pendingPresentation: LootDrop?

    init(gemService: GemService, toastManager: ToastManager? = nil, soundManager: SoundManager? = nil) {
        self.gemService = gemService
        self.toastManager = toastManager
        self.soundManager = soundManager
    }

    func rollForLoot(questRarity: QuestRarity, streakDays: Int) -> LootDrop? {
        let baseChance = switch questRarity {
        case .common: 0.15
        case .rare: 0.20
        case .epic: 0.30
        case .legendary: 0.50
        }

        let streakBonus = min(Double(streakDays) * 0.02, 0.20)
        let totalChance = baseChance + streakBonus

        let roll = Double.random(in: 0.0 ... 1.0)
        guard roll <= totalChance else {
            return nil
        }

        let lootRoll = Double.random(in: 0.0 ... 1.0)
        let gemAmount: Int
        let description: String

        if lootRoll < 0.60 {
            gemAmount = Int.random(in: 5 ... 15)
            description = "Small Gem Pouch"
        } else if lootRoll < 0.85 {
            gemAmount = Int.random(in: 20 ... 40)
            description = "Medium Gem Pouch"
        } else if lootRoll < 0.95 {
            gemAmount = Int.random(in: 50 ... 100)
            description = "Large Gem Pouch"
        } else {
            gemAmount = Int.random(in: 150 ... 250)
            description = "Legendary Jackpot"
        }

        return LootDrop(gemAmount: gemAmount, description: description, rarity: questRarity)
    }

    /// Rolls for a loot drop (quest rarity + streak bonus) and, on a successful
    /// roll, credits the gems to the hero's ledger. The dropped ``LootDrop``
    /// (if any) is published via ``pendingPresentation`` so the hero dashboard
    /// can surface the treasure-chest overlay. This is the post-verification
    /// reward path: it must only be invoked from `QuestService.applyReward`,
    /// which runs on `.autoApproved` submission or parent `.verified` — never on
    /// a `.pending` submission — so a hero cannot farm loot by submitting quests
    /// a parent later rejects. `eventKey` (the completion record name) gives the
    /// gem ledger a deterministic ID, collapsing any cross-device re-delivery
    /// to a single credit.
    @discardableResult
    func rollAndCredit(questRarity: QuestRarity, streakDays: Int, to profile: Profile, eventKey: String) async -> LootDrop? {
        guard let loot = rollForLoot(questRarity: questRarity, streakDays: streakDays) else {
            return nil
        }
        do {
            try await gemService.creditGems(amount: loot.gemAmount, to: profile, source: "lootDrop", eventKey: eventKey, detail: loot.description)
        } catch {
            logger.error("Failed to credit loot drop for profile \(profile.id.recordName, privacy: .private): \(error, privacy: .private)")
            return nil
        }
        pendingPresentation = loot
        return loot
    }

    /// Clears ``pendingPresentation``. Called by the hero dashboard once the
    /// loot overlay has been dismissed so a subsequent drop re-triggers
    /// `.onChange`.
    func clearPendingPresentation() {
        pendingPresentation = nil
    }
}
