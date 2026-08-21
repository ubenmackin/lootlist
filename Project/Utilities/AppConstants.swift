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

    enum Session {
        static let zoneCheckTimeoutSeconds: Double = 5.0
        static let restoreRetryBudget: Int = 2
    }

    static let weekdayCodes = ["sunday", "monday", "tuesday", "wednesday",
                               "thursday", "friday", "saturday"]
    static let weekdayAbbreviated = ["Su", "M", "Tu", "W", "Th", "F", "Sa"]
    static let weekdayShort = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    enum Time {
        static let secondsInWeek: Int = 604_800
    }

    enum Accessories {
        static let levelGate5: Int = 5
        static let levelGate10: Int = 10
        static let levelGate15: Int = 15
        static let levelGate20: Int = 20
    }

    enum CloudKit {
        static let maxRetries: Int = 3
        static let maxFetchPages: Int = 10000
        static let batchQueryChunkSize: Int = 100
        static let maxTrackedFailedRecords: Int = 100
        static let shareAbsenceThreshold: Int = 2
        static let backoffScheduleNanos: [UInt64] = [
            500_000_000,
            1_500_000_000,
            4_000_000_000
        ]
    }

    enum Economy {
        static let earlyBirdHourCutoff: Int = 9
        static let prestigeTitleCycle: Int = 4
        static let totalDefaultAchievementsCount: Int = 12
        static let percentageBase: Double = 100.0
        static let previousWeekDayOffset: Int = -7
        static let payoutCutoffDayOffset: Int = 6
    }

    enum UserInterface {
        static let toastAutoDismissSeconds: Double = 7.0
        static let toastAutoDismissNanos: UInt64 = 7_000_000_000
        static let celebrationAutoDismissSeconds: UInt64 = 6
        static let avatarJpegCompression: Double = 0.8
    }

    enum DailyLogin {
        static let lastHeroProfileRecordNameKey: String = "dailyLoginLastHeroProfileRecordName"
        static let resetWindowHours: Int = 24
    }
}
