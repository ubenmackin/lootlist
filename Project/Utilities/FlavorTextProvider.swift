//
//  FlavorTextProvider.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import Foundation

enum FlavorTextProvider {
    static func questCompletion(rarity: QuestRarity) -> String {
        switch rarity {
        case .common:
            let options = [
                "Another task vanquished!",
                "The kingdom thanks you.",
                "Well done, adventurer.",
                "A fine deed, hero.",
                "The realm grows stronger."
            ]
            return options.randomElement() ?? options[0]
        case .rare:
            let options = [
                "A worthy challenge, conquered!",
                "Your skills grow stronger.",
                "The guild will sing of this.",
                "Impressive work, hero!"
            ]
            return options.randomElement() ?? options[0]
        case .epic:
            let options = [
                "A legendary feat of bravery!",
                "Tales will be told of this deed!",
                "The stars align in your favor!",
                "Heroes are forged in moments like this!"
            ]
            return options.randomElement() ?? options[0]
        case .legendary:
            let options = [
                "THE REALM TREMBLES AT YOUR POWER!",
                "You have achieved the impossible!",
                "A deed worthy of the gods themselves!",
                "Legends speak of warriors like you!"
            ]
            return options.randomElement() ?? options[0]
        }
    }

    static func levelUp(newLevel: Int, title: String) -> String {
        let options = [
            "Your training has paid off. You are now a \(title)!",
            "The path ahead grows clearer. Level \(newLevel) — \(title)!",
            "You have transcended your limits. Welcome to Level \(newLevel)!",
            "A new chapter begins. Rise, \(title)!"
        ]
        return options.randomElement() ?? options[0]
    }

    static func streakMilestone(days: Int) -> String {
        let options = [
            "A magnificent streak of \(days) days! The gods are pleased.",
            "Your dedication is unwavering! \(days) days in a row!",
            "\(days) days of consecutive heroism!",
            "No task is safe from your relentless pursuit! \(days) days!"
        ]
        return options.randomElement() ?? options[0]
    }

    static func emptyQuestBoard() -> String {
        let options = [
            "The realm is safe... for now.",
            "Take a well-deserved rest, hero. Your work is done.",
            "No monsters left to slay. Enjoy the peace.",
            "The quest board is clear. A rare sight indeed!"
        ]
        return options.randomElement() ?? options[0]
    }

    static func overdueNudge() -> String {
        let options = [
            "A lingering challenge awaits your attention.",
            "The time has come to face this unfinished business.",
            "Even heroes need a little push sometimes. You've got this!",
            "This quest is calling out to you. Answer the call!"
        ]
        return options.randomElement() ?? options[0]
    }
}
