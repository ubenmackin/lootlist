//
//  GoalPacingCalculator.swift
//  LootList
//
//  Created by Ben Mackin on 8/29/26.
//

import Foundation
import SwiftUI

/// Calculates time-remaining, required periodic savings, and pacing progress
/// for goals configured with a target deadline.
enum GoalPacingCalculator {
    enum PacingStatus: String, Sendable, CaseIterable {
        case completed
        case ahead
        case onTrack
        case behind
        case pastDue
        case noDeadline

        var displayName: String {
            switch self {
            case .completed: "Completed"
            case .ahead: "Ahead of Schedule"
            case .onTrack: "On Track"
            case .behind: "Behind Schedule"
            case .pastDue: "Past Target Date"
            case .noDeadline: "No Target Date"
            }
        }

        var badgeText: String {
            switch self {
            case .completed: "Completed"
            case .ahead: "Ahead"
            case .onTrack: "On Track"
            case .behind: "Behind"
            case .pastDue: "Past Due"
            case .noDeadline: ""
            }
        }

        var tintColor: Color {
            switch self {
            case .completed, .onTrack:
                Color(DesignSystemConstants.Colors.primaryGreen)
            case .ahead:
                Color(DesignSystemConstants.Colors.accentBlue)
            case .behind:
                Color(DesignSystemConstants.Colors.pendingAmber)
            case .pastDue:
                Color(DesignSystemConstants.Colors.dangerRed)
            case .noDeadline:
                Color.secondary
            }
        }

        var iconSystemName: String {
            switch self {
            case .completed: "checkmark.circle.fill"
            case .ahead: "bolt.fill"
            case .onTrack: "gauge.with.dots.needle.50percent"
            case .behind: "hourglass.badge.plus"
            case .pastDue: "exclamationmark.circle.fill"
            case .noDeadline: "calendar"
            }
        }
    }

    struct PacingSummary: Sendable {
        let status: PacingStatus
        let daysRemaining: Int
        let weeksRemaining: Int
        let weeklyRequiredSavingsDollars: Double
        let remainingPennies: Int64
        let formattedTargetDate: String
        let pacingDescription: String
    }

    /// Evaluates pacing status and weekly savings requirements for a goal.
    static func calculatePacing(
        targetAmountPennies: Int64,
        savedPennies: Int64,
        createdAt: Date,
        targetDate: Date?,
        completedAt: Date? = nil,
        now: Date = Date()
    ) -> PacingSummary? {
        guard let targetDate else { return nil }

        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let startOfTarget = calendar.startOfDay(for: targetDate)
        let startOfCreated = calendar.startOfDay(for: createdAt)

        let daysRemaining = calendar.dateComponents([.day], from: startOfToday, to: startOfTarget).day ?? 0
        let weeksRemaining = max(1, Int(ceil(Double(max(daysRemaining, 1)) / 7.0)))
        let remainingPennies = max(0, targetAmountPennies - savedPennies)
        let weeklyRequiredPennies = Int64(ceil(Double(remainingPennies) / Double(weeksRemaining)))
        let weeklyDollars = Double(weeklyRequiredPennies) / 100.0

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .none
        let formattedDate = dateFormatter.string(from: targetDate)

        let isCompleted = completedAt != nil || savedPennies >= targetAmountPennies

        let status: PacingStatus
        let description: String

        if isCompleted {
            status = .completed
            description = "Goal Achieved!"
        } else if daysRemaining < 0 {
            status = .pastDue
            let daysPast = abs(daysRemaining)
            description = "\(daysPast) day\(daysPast == 1 ? "" : "s") past target date (\(formattedDate))"
        } else {
            let totalDays = max(1, calendar.dateComponents([.day], from: startOfCreated, to: startOfTarget).day ?? 1)
            let daysElapsed = max(0, calendar.dateComponents([.day], from: startOfCreated, to: startOfToday).day ?? 0)
            let expectedPennies = Int64(Double(targetAmountPennies) * min(1.0, Double(daysElapsed) / Double(totalDays)))
            let tolerancePennies = max(Int64(100), targetAmountPennies / 10) // 10% or $1.00

            if savedPennies >= expectedPennies + tolerancePennies {
                status = .ahead
            } else if savedPennies < expectedPennies - tolerancePennies {
                status = .behind
            } else {
                status = .onTrack
            }

            if daysRemaining == 0 {
                description = "Due today · \(CurrencyFormatter.string(Double(remainingPennies) / 100.0)) left"
            } else if daysRemaining <= 7 {
                description = "\(daysRemaining) day\(daysRemaining == 1 ? "" : "s") left · \(CurrencyFormatter.string(Double(remainingPennies) / 100.0)) left"
            } else {
                description = "Save \(CurrencyFormatter.string(weeklyDollars))/week to reach by \(formattedDate)"
            }
        }

        return PacingSummary(
            status: status,
            daysRemaining: daysRemaining,
            weeksRemaining: weeksRemaining,
            weeklyRequiredSavingsDollars: weeklyDollars,
            remainingPennies: remainingPennies,
            formattedTargetDate: formattedDate,
            pacingDescription: description
        )
    }
}
