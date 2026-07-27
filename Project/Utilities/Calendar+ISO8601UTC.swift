//
//  Calendar+ISO8601UTC.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation

extension Calendar {
    static let iso8601UTC: Calendar = {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone(abbreviation: "UTC") ?? .current
        return cal
    }()
}
