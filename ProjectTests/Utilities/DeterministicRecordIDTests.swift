//
//  DeterministicRecordIDTests.swift
//  LootList
//
//  Created by Ben Mackin on 11/1/26.
//

import Foundation
@testable import LootList
import Testing

struct DeterministicRecordIDTests {
    private let period = "period-fam1-hero1-9999"

    @Test
    func `realtimePayoutCompletion returns the per-event settlement name`() {
        #expect(
            DeterministicRecordID.realtimePayoutCompletion(periodRecordName: period, completionRecordName: "C123")
                == "rt-period-fam1-hero1-9999-C123"
        )
    }

    @Test
    func `realtimePayoutCompletionPrefix returns the per-event prefix`() {
        #expect(DeterministicRecordID.realtimePayoutCompletionPrefix(periodRecordName: period) == "rt-period-fam1-hero1-9999-")
    }

    @Test
    func `legacy realtimePayout name stays the bare period`() {
        #expect(DeterministicRecordID.realtimePayout(periodRecordName: period) == "rt-period-fam1-hero1-9999")
    }

    @Test
    func `per-event name never equals the legacy name and always starts with the prefix`() {
        let completion = UUID().uuidString
        let perEvent = DeterministicRecordID.realtimePayoutCompletion(periodRecordName: period, completionRecordName: completion)
        let legacy = DeterministicRecordID.realtimePayout(periodRecordName: period)
        let prefix = DeterministicRecordID.realtimePayoutCompletionPrefix(periodRecordName: period)

        #expect(perEvent != legacy)
        #expect(perEvent.hasPrefix(prefix))
    }
}
