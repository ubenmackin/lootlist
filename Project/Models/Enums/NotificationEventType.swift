import Foundation

enum NotificationEventType: String, Codable, CaseIterable, Sendable {
    case questAssigned
    case questCompleted
    case questNeedsReview
    case questMissed
    case levelUp
    case goldEarned
    case spendingLogged
    case trophyEarned
    case streakMilestone

    var displayName: String {
        switch self {
        case .questAssigned: "Quest Assigned"
        case .questCompleted: "Quest Slain"
        case .questNeedsReview: "Quest Needs Review"
        case .questMissed: "Quest Missed"
        case .levelUp: "Level Up"
        case .goldEarned: "Sunday Loot Day"
        case .spendingLogged: "Spending Logged"
        case .trophyEarned: "Trophy Earned"
        case .streakMilestone: "Streak Milestone"
        }
    }

    var iconSystemName: String {
        switch self {
        case .questAssigned: "scroll.fill"
        case .questCompleted: "checkmark.seal.fill"
        case .questNeedsReview: "checkmark.shield.fill"
        case .questMissed: "exclamationmark.triangle.fill"
        case .levelUp: "star.fill"
        case .goldEarned: "circle.hexagongrid.fill"
        case .spendingLogged: "receipt.fill"
        case .trophyEarned: "trophy.fill"
        case .streakMilestone: "flame.fill"
        }
    }

    var defaultEnabledForHero: Bool {
        switch self {
        case .questAssigned,
             .questMissed,
             .levelUp,
             .goldEarned,
             .trophyEarned,
             .streakMilestone:
            true
        case .questCompleted,
             .questNeedsReview,
             .spendingLogged:
            false
        }
    }

    var defaultEnabledForParent: Bool {
        switch self {
        case .questAssigned, .spendingLogged:
            false
        default:
            true
        }
    }
}
