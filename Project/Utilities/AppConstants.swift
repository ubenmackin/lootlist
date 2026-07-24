import Foundation

/// Centralized constants for the LootList application.
enum AppConstants {
    /// XP and Leveling progression constants.
    enum Experience {
        /// Base XP step required per level increment in quadratic progression.
        static let stepBase: Int = 100

        /// Number of levels between unlocking new avatar accessory options.
        static let accessoryCadence: Int = 5
    }

    /// Quest rarity XP values and qualification thresholds.
    enum Rarity {
        /// XP reward for Common quests.
        static let commonXP: Int = 50

        /// XP reward for Rare quests.
        static let rareXP: Int = 100

        /// XP reward for Epic quests.
        static let epicXP: Int = 250

        /// XP reward for Legendary quests.
        static let legendaryXP: Int = 500
    }

    /// CloudKit discovery and synchronization pulse settings.
    enum Sync {
        /// Maximum retry attempts during initial shared zone discovery pulse on cold launch.
        static let maxPulseAttempts: Int = 3

        /// Delay duration in nanoseconds between shared zone pulse attempts (1 second).
        static let pulseDelayNanoseconds: UInt64 = 1_000_000_000
    }

    /// Time calculations and date interval constants.
    enum Time {
        /// Days in a standard calendar week.
        static let daysInWeek: Int = 7

        /// Hours in a standard day.
        static let hoursInDay: Int = 24

        /// Minutes in an hour.
        static let minutesInHour: Int = 60

        /// Seconds in a minute.
        static let secondsInMinute: Int = 60

        /// Total seconds in a 7-day week (7 * 24 * 60 * 60 = 604,800).
        static let secondsInWeek: Int = daysInWeek * hoursInDay * minutesInHour * secondsInMinute
    }

    /// Avatar accessory unlock level gates.
    enum Accessories {
        static let levelGate5: Int = 5
        static let levelGate10: Int = 10
        static let levelGate15: Int = 15
        static let levelGate20: Int = 20
    }
}
