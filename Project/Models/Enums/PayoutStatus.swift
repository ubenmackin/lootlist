import Foundation

enum PayoutStatus: String, Codable, CaseIterable, Sendable {
    case active

    case payoutPending

    case paid

    var displayName: String {
        switch self {
        case .active: "Active"
        case .payoutPending: "Loot Day Pending"
        case .paid: "Paid"
        }
    }

    var iconSystemName: String {
        switch self {
        case .active: "bolt.fill"
        case .payoutPending: "hourglass"
        case .paid: "checkmark.seal.fill"
        }
    }

    var isResolved: Bool {
        self == .paid
    }
}
