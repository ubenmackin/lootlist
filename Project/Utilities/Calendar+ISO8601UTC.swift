import Foundation

extension Calendar {
    /// A shared ISO 8601 calendar fixed to UTC, used for all server-side
    /// and data-layer date calculations (week boundaries, start-of-day, etc.).
    static let iso8601UTC: Calendar = {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()
}
