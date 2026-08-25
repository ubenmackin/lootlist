//
//  PayoutDay.swift
//  LootList
//
//  Created by Ben Mackin on 8/17/26.
//

import Foundation

enum PayoutDay: String, Codable, CaseIterable, Sendable, Identifiable {
    case sunday
    case monday
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .sunday: "Sunday"
        case .monday: "Monday"
        case .tuesday: "Tuesday"
        case .wednesday: "Wednesday"
        case .thursday: "Thursday"
        case .friday: "Friday"
        case .saturday: "Saturday"
        }
    }

    /// User-facing payout-day title; the `lootDay` property name is a legacy
    /// identifier and stays as-is.
    var lootDayTitle: String {
        "\(displayName) Allowance Day"
    }

    /// Calendar weekday integer value (Sunday = 1, Monday = 2, ..., Saturday = 7).
    var calendarWeekday: Int {
        switch self {
        case .sunday: 1
        case .monday: 2
        case .tuesday: 3
        case .wednesday: 4
        case .thursday: 5
        case .friday: 6
        case .saturday: 7
        }
    }

    var weekdayNumber: Int {
        calendarWeekday
    }

    var nextDay: PayoutDay {
        let next = (calendarWeekday % 7) + 1
        return PayoutDay.from(weekday: next)
    }

    static func from(weekday: Int) -> PayoutDay {
        switch weekday {
        case 1: .sunday
        case 2: .monday
        case 3: .tuesday
        case 4: .wednesday
        case 5: .thursday
        case 6: .friday
        case 7: .saturday
        default: .sunday
        }
    }
}
