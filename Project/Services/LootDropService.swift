//
//  LootDropService.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import Foundation
import os
import SwiftUI

public struct LootDrop: Sendable, Equatable {
    public let gemAmount: Int
    public let description: String
    public let rarity: QuestRarity

    public init(gemAmount: Int, description: String, rarity: QuestRarity) {
        self.gemAmount = gemAmount
        self.description = description
        self.rarity = rarity
    }
}

@MainActor
@Observable
final class LootDropService {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "LootDrop")
    let gemService: GemService
    let toastManager: ToastManager?
    let soundManager: SoundManager?

    private(set) var pendingPresentation: LootDrop?
    var rollProvider: ((QuestRarity, Int) -> LootDrop?)?

    init(gemService: GemService, toastManager: ToastManager? = nil, soundManager: SoundManager? = nil) {
        self.gemService = gemService
        self.toastManager = toastManager
        self.soundManager = soundManager
    }

    func rollForLoot(questRarity: QuestRarity, streakDays: Int) -> LootDrop? {
        if let rollProvider {
            return rollProvider(questRarity, streakDays)
        }
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

    @discardableResult
    func rollAndCredit(questRarity: QuestRarity, streakDays: Int, to profile: Profile, eventKey: String) async -> LootDrop? {
        if let cache = gemService.cacheService {
            let ledgerID = GemLedger.deterministicRecordID(
                profileRecordName: profile.id.recordName,
                eventKey: eventKey,
                source: "lootDrop",
                zoneID: profile.id.zoneID
            )
            if cache.fetchGemLedger(recordName: ledgerID.recordName, family: profile.family.recordID.recordName) != nil {
                return nil
            }
        }

        guard let loot = self.rollForLoot(questRarity: questRarity, streakDays: streakDays) else {
            return nil
        }
        do {
            let credited = try await gemService.creditGems(amount: loot.gemAmount, to: profile, source: "lootDrop", eventKey: eventKey, detail: loot.description)
            guard credited else { return nil }
        } catch {
            logger.error("Failed to credit loot drop for profile \(profile.id.recordName, privacy: .private): \(error, privacy: .private)")
            return nil
        }
        pendingPresentation = loot
        return loot
    }

    func clearPendingPresentation() {
        pendingPresentation = nil
    }
}
