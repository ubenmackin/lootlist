//
//  CalendarUtilsTests.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation
@testable import LootList
import Testing

struct CalendarUtilsTests {
    @Test
    func `iSO8601 UTC calendar identifier and timezone`() {
        let cal = Calendar.iso8601UTC

        #expect(cal.identifier == .iso8601)
        #expect(cal.timeZone.secondsFromGMT() == 0)
        #expect(cal.firstWeekday == 2) // Monday in ISO8601
    }

    @Test
    func `start of day calculation in UTC`() {
        let cal = Calendar.iso8601UTC
        let date = Date(timeIntervalSince1970: 1_700_000_000) // Fixed epoch timestamp
        let startOfDay = cal.startOfDay(for: date)

        let components = cal.dateComponents([.hour, .minute, .second], from: startOfDay)
        #expect(components.hour == 0)
        #expect(components.minute == 0)
        #expect(components.second == 0)
    }
}
