//
//  StreakCalculatorTests.swift
//  LootList
//
//  Created by Ben Mackin on 2026-08-04
//

import Foundation
@testable import LootList
import Testing

struct StreakCalculatorTests {
    private func makeLog(
        recordName: String,
        completerRecordName: String = "hero1",
        completedDate: Date,
        verificationStatus: VerificationStatus,
        familyRecordName: String = "TestFamily"
    ) -> QuestCompletionCache {
        QuestCompletionCache(
            recordName: recordName,
            questRecordName: "quest1",
            familyRecordName: familyRecordName,
            completerRecordName: completerRecordName,
            completedDate: completedDate,
            weekOf: completedDate,
            verificationStatus: verificationStatus.rawValue,
            approvalMode: (verificationStatus == .autoApproved)
                ? ApprovalMode.autoApprove.rawValue
                : ApprovalMode.parentVerify.rawValue,
            verifiedByRecordName: nil,
            verifiedDate: nil
        )
    }

    @Test
    func `empty logs yield zero streak`() {
        #expect(StreakCalculator.computeStreak(from: []) == 0)
    }

    @Test
    func `consecutive-day logs yield the streak count`() throws {
        let calendar = Calendar.iso8601UTC
        let today = calendar.startOfDay(for: Date())
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: today))
        let twoDaysAgo = try #require(calendar.date(byAdding: .day, value: -2, to: today))

        let logs = [
            makeLog(recordName: "l0", completedDate: today, verificationStatus: .autoApproved),
            makeLog(recordName: "l1", completedDate: yesterday, verificationStatus: .verified),
            makeLog(recordName: "l2", completedDate: twoDaysAgo, verificationStatus: .autoApproved)
        ]

        #expect(StreakCalculator.computeStreak(from: logs) == 3)
    }

    @Test
    func `a gap resets the streak from the anchor forward`() throws {
        let calendar = Calendar.iso8601UTC
        let today = calendar.startOfDay(for: Date())
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: today))
        let threeDaysAgo = try #require(calendar.date(byAdding: .day, value: -3, to: today))
        let fourDaysAgo = try #require(calendar.date(byAdding: .day, value: -4, to: today))

        // Today + yesterday form an unbroken 2-day run ending now; an older
        // completion two days before that is separated by a gap, so it must
        // not extend the count.
        let logs = [
            makeLog(recordName: "l0", completedDate: today, verificationStatus: .autoApproved),
            makeLog(recordName: "l1", completedDate: yesterday, verificationStatus: .verified),
            makeLog(recordName: "l2", completedDate: threeDaysAgo, verificationStatus: .autoApproved),
            makeLog(recordName: "l3", completedDate: fourDaysAgo, verificationStatus: .autoApproved)
        ]

        #expect(StreakCalculator.computeStreak(from: logs) == 2)
    }

    @Test
    func `pending logs are not counted toward a streak`() throws {
        let calendar = Calendar.iso8601UTC
        let today = calendar.startOfDay(for: Date())
        let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: today))

        let logs = [
            makeLog(recordName: "l0", completedDate: today, verificationStatus: .pending),
            makeLog(recordName: "l1", completedDate: yesterday, verificationStatus: .pending)
        ]

        #expect(StreakCalculator.computeStreak(from: logs) == 0)
    }
}
