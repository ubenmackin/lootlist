//
//  QuestSchedule.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation

enum QuestSchedule: String, Codable, CaseIterable, Sendable {
    case specificDays

    case weeklyFlexible

    var displayName: String {
        switch self {
        case .specificDays: "Specific Days"
        case .weeklyFlexible: "Flexible (Any Day)"
        }
    }

    var iconSystemName: String {
        switch self {
        case .specificDays: "calendar"
        case .weeklyFlexible: "calendar.badge.clock"
        }
    }

    var requiresSpecificDays: Bool {
        self == .specificDays
    }
}
