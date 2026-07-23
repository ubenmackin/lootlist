import Foundation
import SwiftUI

enum QuestRarity: String, CaseIterable, Identifiable, Codable, Sendable {
    case common = "Common"
    case rare = "Rare"
    case epic = "Epic"
    case legendary = "Legendary"

    var id: String { rawValue }

    var xpReward: Int {
        switch self {
        case .common: 50
        case .rare: 100
        case .epic: 250
        case .legendary: 500
        }
    }

    var color: Color {
        switch self {
        case .common: Color.secondary
        case .rare: Color.blue
        case .epic: Color.purple
        case .legendary: Color.orange
        }
    }

    var iconSystemName: String {
        switch self {
        case .common: "shield"
        case .rare: "sparkles"
        case .epic: "star.fill"
        case .legendary: "crown.fill"
        }
    }

    static func from(xp: Int) -> QuestRarity {
        if xp >= 500 { return .legendary }
        if xp >= 250 { return .epic }
        if xp >= 100 { return .rare }
        return .common
    }
}
