//
//  PayoutPolicy.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation

enum PayoutPolicy: String, Codable, CaseIterable, Sendable {
    case perQuest
    case allOrNothing
    case realTime

    var displayName: String {
        switch self {
        case .perQuest: "Pay Per Quest (Standard)"
        case .allOrNothing: "All-or-Nothing (Strict 100%)"
        case .realTime: "Real-Time (Instant Settlement)"
        }
    }

    var subtitle: String {
        switch self {
        case .perQuest: "Money is earned per quest and settled in one batched weekly payout."
        case .allOrNothing: "Hero must complete 100% of assigned weekly quests to receive their allowance."
        case .realTime: "Each quest completion is settled and ready for payout immediately."
        }
    }

    var iconSystemName: String {
        switch self {
        case .perQuest: "banknote"
        case .allOrNothing: "trophy.fill"
        case .realTime: "bolt.circle.fill"
        }
    }
}
