//
//  NotificationEventType.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation

enum NotificationCategory: String, CaseIterable, Sendable {
    case quests = "Quests"
    case rewards = "Rewards & Progress"
    case treasury = "Treasury"

    var icon: String {
        switch self {
        case .quests: "⚔️"
        case .rewards: "🏆"
        case .treasury: "🏛️"
        }
    }

    var footer: String {
        switch self {
        case .quests: "Alerts for quest lifecycle — assignments, reviews, and outcomes."
        case .rewards: "Celebrate milestones, achievements, and streaks."
        case .treasury: "Weekly loot payouts and spending activity."
        }
    }
}

enum NotificationEventType: String, Codable, CaseIterable, Sendable {
    case questAssigned
    case questCompleted
    case questNeedsReview
    case questRejected
    case questMissed
    case levelUp
    case goldEarned
    case spendingLogged
    case trophyEarned
    case streakMilestone

    var displayName: String {
        switch self {
        case .questAssigned: "Quest Assigned"
        case .questCompleted: "Quest Completed"
        case .questNeedsReview: "Quest Needs Review"
        case .questRejected: "Quest Rejected"
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
        case .questRejected: "xmark.seal.fill"
        case .questMissed: "exclamationmark.triangle.fill"
        case .levelUp: "star.fill"
        case .goldEarned: "banknote"
        case .spendingLogged: "receipt.fill"
        case .trophyEarned: "trophy.fill"
        case .streakMilestone: "flame.fill"
        }
    }

    var category: NotificationCategory {
        switch self {
        case .questAssigned, .questCompleted, .questNeedsReview, .questRejected, .questMissed:
            .quests
        case .levelUp, .trophyEarned, .streakMilestone:
            .rewards
        case .goldEarned, .spendingLogged:
            .treasury
        }
    }

    var isRelevantForParent: Bool {
        switch self {
        case .questNeedsReview, .levelUp, .goldEarned, .spendingLogged, .trophyEarned, .streakMilestone:
            true
        case .questAssigned, .questCompleted, .questRejected, .questMissed:
            false
        }
    }

    var isRelevantForHero: Bool {
        switch self {
        case .questAssigned, .questCompleted, .questRejected, .questMissed, .levelUp, .goldEarned, .trophyEarned, .streakMilestone:
            true
        case .questNeedsReview, .spendingLogged:
            false
        }
    }

    var defaultEnabledForHero: Bool {
        switch self {
        case .questAssigned,
             .questMissed,
             .questRejected,
             .questCompleted,
             .levelUp,
             .goldEarned,
             .trophyEarned,
             .streakMilestone:
            true
        case .questNeedsReview,
             .spendingLogged:
            false
        }
    }

    var defaultEnabledForParent: Bool {
        switch self {
        case .questNeedsReview, .levelUp, .goldEarned, .spendingLogged, .trophyEarned, .streakMilestone:
            true
        case .questAssigned, .questCompleted, .questRejected, .questMissed:
            false
        }
    }
}
