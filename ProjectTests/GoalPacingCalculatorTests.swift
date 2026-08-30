//
//  GoalPacingCalculatorTests.swift
//  LootListTests
//
//  Created by Ben Mackin on 8/29/26.
//

import Foundation
@testable import LootList
import Testing

struct GoalPacingCalculatorTests {
    @Test
    func `nil target date returns nil`() {
        let summary = GoalPacingCalculator.calculatePacing(
            targetAmountPennies: 10000,
            savedPennies: 2000,
            createdAt: Date(),
            targetDate: nil
        )
        #expect(summary == nil)
    }

    @Test
    func `completed goal returns completed status`() {
        let target = Date().addingTimeInterval(86400 * 30)
        let summary = GoalPacingCalculator.calculatePacing(
            targetAmountPennies: 10000,
            savedPennies: 10000,
            createdAt: Date(),
            targetDate: target
        )
        #expect(summary?.status == .completed)
        #expect(summary?.pacingDescription == "Goal Achieved!")
    }

    @Test
    func `past due goal returns past due status`() {
        let now = Date()
        let created = now.addingTimeInterval(-86400 * 30)
        let pastTarget = now.addingTimeInterval(-86400 * 5)

        let summary = GoalPacingCalculator.calculatePacing(
            targetAmountPennies: 10000,
            savedPennies: 2000,
            createdAt: created,
            targetDate: pastTarget,
            now: now
        )
        #expect(summary?.status == .pastDue)
        #expect(summary?.daysRemaining ?? 0 < 0)
    }

    @Test
    func `ahead of schedule pacing`() {
        let now = Date()
        let created = now.addingTimeInterval(-86400 * 10)
        let target = now.addingTimeInterval(86400 * 10) // midpoint of 20 days

        // Total 20 days, 10 days elapsed (50% expected = $50.00). Saved is $80.00 -> Ahead!
        let summary = GoalPacingCalculator.calculatePacing(
            targetAmountPennies: 10000,
            savedPennies: 8000,
            createdAt: created,
            targetDate: target,
            now: now
        )
        #expect(summary?.status == .ahead)
    }

    @Test
    func `behind schedule pacing`() {
        let now = Date()
        let created = now.addingTimeInterval(-86400 * 15)
        let target = now.addingTimeInterval(86400 * 5) // 75% through 20 days

        // Expected is $75.00, saved is $20.00 -> Behind!
        let summary = GoalPacingCalculator.calculatePacing(
            targetAmountPennies: 10000,
            savedPennies: 2000,
            createdAt: created,
            targetDate: target,
            now: now
        )
        #expect(summary?.status == .behind)
    }

    @Test
    func `weekly required savings math`() {
        let now = Date()
        let target = now.addingTimeInterval(86400 * 28) // 4 weeks

        // $100.00 target, $20.00 saved -> $80.00 remaining over 4 weeks = $20.00/week
        let summary = GoalPacingCalculator.calculatePacing(
            targetAmountPennies: 10000,
            savedPennies: 2000,
            createdAt: now,
            targetDate: target,
            now: now
        )
        #expect(summary?.weeksRemaining == 4)
        #expect(summary?.weeklyRequiredSavingsDollars == 20.0)
    }
}
