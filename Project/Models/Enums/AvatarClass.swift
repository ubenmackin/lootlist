import Foundation

enum AvatarClass: String, Codable, CaseIterable, Sendable {
    case knight
    case mage
    case rogue
    case guardian
    case healer

    var displayName: String {
        switch self {
        case .knight: "Knight"
        case .mage: "Mage"
        case .rogue: "Rogue"
        case .guardian: "Guardian"
        case .healer: "Healer"
        }
    }

    var tagline: String {
        switch self {
        case .knight: "Brave and steadfast"
        case .mage: "Wielder of arcane chores"
        case .rogue: "Quick and crafty"
        case .guardian: "Shield of the household"
        case .healer: "Keeper of the party"
        }
    }

    var iconSystemName: String {
        switch self {
        case .knight: "shield.fill"
        case .mage: "wand.and.stars.inverse"
        case .rogue: "theatermasks.fill"
        case .guardian: "checkerboard.shield"
        case .healer: "cross.case.fill"
        }
    }

    var presetPrefix: String {
        rawValue
    }
}
