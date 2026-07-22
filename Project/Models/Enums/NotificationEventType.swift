import Foundation

enum NotificationEventType: String, Codable, CaseIterable, Sendable {

    case questAssigned

    case questCompleted

    case questNeedsReview

    case questMissed

    case goldEarned

    case spendingLogged

    case trophyEarned

    case streakMilestone

    var displayName: String {
        switch self {
        case .questAssigned:    "Quest Assigned"
        case .questCompleted:   "Quest Slain"
        case .questNeedsReview: "Quest Needs Review"
        case .questMissed:      "Quest Missed"
        case .goldEarned:       "Loot Day"
        case .spendingLogged:   "Spending Logged"
        case .trophyEarned:     "Trophy Earned"
        case .streakMilestone:  "Streak Milestone"
        }
    }

    var iconSystemName: String {
        switch self {
        case .questAssigned:    "scribble"
        case .questCompleted:   "sword.fill"
        case .questNeedsReview: "eye.fill"
        case .questMissed:      "exclamationmark.triangle.fill"
        case .goldEarned:       "dollarsign.circle.fill"
        case .spendingLogged:   "receipt.fill"
        case .trophyEarned:     "trophy.fill"
        case .streakMilestone:  "flame.fill"
        }
    }

    var defaultEnabledForHero: Bool {
        switch self {
        case .questAssigned,
             .questMissed,
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
