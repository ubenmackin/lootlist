import Foundation

enum PayoutPolicy: String, Codable, CaseIterable, Sendable {
    case perQuest
    case allOrNothing

    var displayName: String {
        switch self {
        case .perQuest: "Pay Per Quest (Standard)"
        case .allOrNothing: "All-or-Nothing (Strict 100%)"
        }
    }
}
