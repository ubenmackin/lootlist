import Foundation

enum UserRole: String, Codable, CaseIterable, Sendable {
    case guildMaster

    case ranger

    case hero

    var displayName: String {
        switch self {
        case .guildMaster: "Guild Master"
        case .ranger: "Ranger"
        case .hero: "Hero"
        }
    }

    var iconSystemName: String {
        switch self {
        case .guildMaster: "crown.fill"
        case .ranger: "bowtie.fill"
        case .hero: "figure.and.child.holdinghands"
        }
    }

    var isParent: Bool {
        switch self {
        case .guildMaster, .ranger: true
        case .hero: false
        }
    }

    var isOwner: Bool {
        self == .guildMaster
    }
}
