//
//  AppConstants.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation

enum AppConstants {
    enum Experience {
        static let stepBase: Int = 100
        static let accessoryCadence: Int = 5
    }

    enum Rarity {
        static let commonXP: Int = 50
        static let rareXP: Int = 100
        static let epicXP: Int = 250
        static let legendaryXP: Int = 500
    }

    enum Sync {
        static let maxPulseAttempts: Int = 3
        static let pulseDelayNanoseconds: UInt64 = 1_000_000_000
    }

    static let weekdayCodes = ["sunday", "monday", "tuesday", "wednesday",
                               "thursday", "friday", "saturday"]
    static let weekdayDisplay = ["Sunday", "Monday", "Tuesday", "Wednesday",
                                 "Thursday", "Friday", "Saturday"]
    static let weekdayAbbreviated = ["Su", "M", "Tu", "W", "Th", "F", "Sa"]
    static let weekdayShort = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    enum Time {
        static let daysInWeek: Int = 7
        static let hoursInDay: Int = 24
        static let minutesInHour: Int = 60
        static let secondsInMinute: Int = 60
        static let secondsInWeek: Int = daysInWeek * hoursInDay * minutesInHour * secondsInMinute
    }

    enum Accessories {
        static let levelGate5: Int = 5
        static let levelGate10: Int = 10
        static let levelGate15: Int = 15
        static let levelGate20: Int = 20
    }
}
