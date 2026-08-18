//
//  MascotCompanion.swift
//  LootList
//  Created by Ben Mackin on 8/17/26.
//

import SwiftUI

enum MascotState: Sendable, Equatable {
    case idle
    case inProgress
    case encouraging
    case celebrating
    case bonusClaimed
}

enum MascotCompanion: String, CaseIterable, Codable, Sendable {
    case owl
    case dragon
    case fairy
    case fox
    case cat

    var name: String {
        switch self {
        case .owl: "Sage"
        case .dragon: "Ember"
        case .fairy: "Pip"
        case .fox: "Scout"
        case .cat: "Whiskers"
        }
    }

    var tagline: String {
        switch self {
        case .owl: "Wise & bookish"
        case .dragon: "Fierce & enthusiastic"
        case .fairy: "Cheerful & sparkly"
        case .fox: "Clever & sneaky"
        case .cat: "Chill & encouraging"
        }
    }

    var iconSystemName: String {
        switch self {
        case .owl: "books.vertical"
        case .dragon: "flame"
        case .fairy: "sparkles"
        case .fox: "leaf"
        case .cat: "zzz"
        }
    }

    var themeColor: Color {
        switch self {
        case .owl: .blue
        case .dragon: .red
        case .fairy: .pink
        case .fox: .orange
        case .cat: .purple
        }
    }

    func dialogue(state: MascotState, objective _: BonusObjective?) -> String {
        switch self {
        case .owl: owlDialogue(state: state)
        case .dragon: dragonDialogue(state: state)
        case .fairy: fairyDialogue(state: state)
        case .fox: foxDialogue(state: state)
        case .cat: catDialogue(state: state)
        }
    }

    private func owlDialogue(state: MascotState) -> String {
        switch state {
        case .idle: "Hoo! A new day of quests awaits us. Let's begin!"
        case .inProgress: "Excellent progress. Knowledge and gems are accumulating."
        case .encouraging: "Time is fleeting! Let's focus on completing our remaining tasks."
        case .celebrating: "Splendid! All quests completed. Truly wise work today."
        case .bonusClaimed: "A marvelous achievement. The bonus is yours!"
        }
    }

    private func dragonDialogue(state: MascotState) -> String {
        switch state {
        case .idle: "RAWR! Let's crush those quests today!"
        case .inProgress: "We're on fire! Keep going!"
        case .encouraging: "Don't let the fire die out! We still have quests to slay!"
        case .celebrating: "VICTORY! We burned through all the quests today!"
        case .bonusClaimed: "EPIC LOOT! You claimed the bonus!"
        }
    }

    private func fairyDialogue(state: MascotState) -> String {
        switch state {
        case .idle: "Sparkles! A shiny new day for magical quests!"
        case .inProgress: "You're doing wonderfully! So magical!"
        case .encouraging: "Let's sprinkle some fairy dust and finish these quests!"
        case .celebrating: "Yay! A perfect day! Sparkles everywhere!"
        case .bonusClaimed: "So shiny! Enjoy your bonus gems!"
        }
    }

    private func foxDialogue(state: MascotState) -> String {
        switch state {
        case .idle: "Let's be quick and clever today! Quests won't know what hit them."
        case .inProgress: "Sneaky! We're knocking them out one by one."
        case .encouraging: "No time to rest! Let's outsmart the remaining quests."
        case .celebrating: "Too clever! All quests done and dusted."
        case .bonusClaimed: "Snagged the bonus! Great job, partner."
        }
    }

    private func catDialogue(state: MascotState) -> String {
        switch state {
        case .idle: "Yawn... Oh, quests? Yeah, we got this. Eventually."
        case .inProgress: "Purr... Nice job. I might even help with the next one."
        case .encouraging: "Meow... The quests aren't going to finish themselves, you know."
        case .celebrating: "Purrfect. Now we can both take a nap."
        case .bonusClaimed: "Cool. A bonus. Now scratch behind my ears."
        }
    }
}
