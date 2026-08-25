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

    /// Determines whether a quest schedule represents multi-occurrence (more than 1 required completion or day).
    static func isMultiOccurrence(schedule: QuestSchedule, targetCount: Int, specificDaysCount: Int) -> Bool {
        switch schedule {
        case .weeklyFlexible:
            targetCount > 1
        case .specificDays:
            specificDaysCount > 1
        }
    }

    /// Convenience overload accepting an optional collection/array of specific day codes.
    static func isMultiOccurrence(schedule: QuestSchedule, targetCount: Int, specificDays: [String]?) -> Bool {
        isMultiOccurrence(schedule: schedule, targetCount: targetCount, specificDaysCount: specificDays?.count ?? 0)
    }
}
