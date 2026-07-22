import Foundation

enum QuestSchedule: String, Codable, CaseIterable, Sendable {

    case specificDays

    case weeklyFlexible

    case allOrNothing

    var displayName: String {
        switch self {
        case .specificDays:   "Specific Days"
        case .weeklyFlexible: "Flexible (Any Day)"
        case .allOrNothing:   "All-or-Nothing"
        }
    }

    var iconSystemName: String {
        switch self {
        case .specificDays:   "calendar"
        case .weeklyFlexible: "calendar.badge.clock"
        case .allOrNothing:  "link.circle"
        }
    }

    var requiresSpecificDays: Bool { self == .specificDays }
}
