//
//  TreasuryViewModel.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import Observation

@MainActor
@Observable
final class TreasuryViewModel {
    private let treasury: TreasuryService

    private let spending: any SpendingService

    private let appState: AppState

    private(set) var balance: Double?

    private(set) var weeklyBreakdown: TreasuryService.WeeklyBreakdown?

    private(set) var allowancePeriod: AllowancePeriod?

    private(set) var spendingLog: [LedgerEntryCache] = []

    private(set) var isLoading: Bool = false

    private(set) var errorMessage: String?

    init(treasury: TreasuryService,
         spending: any SpendingService,
         appState: AppState)
    {
        self.treasury = treasury
        self.spending = spending
        self.appState = appState
    }

    func rebuildLists(logs: [QuestCompletionCache], ledgers: [LedgerEntryCache], quests: [QuestCache], allowancePeriods: [AllowancePeriodCache], showAllTime: Bool) {
        guard let profile = appState.currentProfile else { return }
        let profileName = profile.id.recordName

        let profileLogs = logs.filter { $0.completerRecordName == profileName }
        let profileLedgers = ledgers.filter { $0.profileRecordName == profileName }

        let approvedLogs = profileLogs.filter {
            $0.verificationStatusEnum == .autoApproved || $0.verificationStatusEnum == .verified
        }

        let goldFromQuests = GoldCalculation.totalGold(for: quests, approvedLogs: approvedLogs)

        let bonusGold = profileLedgers.filter { $0.amount > 0 }.reduce(into: 0.0) { $0 += $1.amount }
        let spent = profileLedgers.filter { $0.amount < 0 }.reduce(into: 0.0) { $0 += $1.amount }

        balance = goldFromQuests + bonusGold + spent

        let weekOf = WeekMath.weekOf(date: Date())
        let weekRange = WeekMath.weekRange(starting: weekOf)

        let currentAllowance = allowancePeriods.first {
            $0.profileRecordName == profileName && $0.weekOf == weekOf
        }
        let payoutStatus = currentAllowance?.statusEnum
        let paidAmount = currentAllowance?.paidAmount
        if let zoneID = appState.familyZoneID {
            allowancePeriod = currentAllowance?.toAllowancePeriod(zoneID: zoneID)
        } else {
            allowancePeriod = nil
        }

        let weekLogs = approvedLogs.filter { weekRange.contains($0.weekOf) }
        var weekQuestsGold = GoldCalculation.totalGold(for: quests, approvedLogs: weekLogs)

        let assignedQuests = quests.filter {
            $0.assigneeRecordName == profileName && weekRange.contains($0.weekOf)
        }
        let fullyCompletedCount = assignedQuests.filter { quest in
            let qApprovedLogs = weekLogs.filter { $0.questRecordName == quest.recordName }
            return qApprovedLogs.count >= quest.targetCount
        }.count

        if profile.payoutPolicy == .allOrNothing,
           !assignedQuests.isEmpty,
           fullyCompletedCount < assignedQuests.count
        {
            weekQuestsGold = 0
        }

        let weekLedgers = profileLedgers.filter { weekRange.contains($0.date) }
        let weekBonusGold = weekLedgers.filter { $0.amount > 0 }.reduce(into: 0.0) { $0 += $1.amount }
        let weekSpent = weekLedgers.filter { $0.amount < 0 }.reduce(into: 0.0) { $0 += $1.amount }

        let totalEarned = weekQuestsGold + weekBonusGold

        weeklyBreakdown = TreasuryService.WeeklyBreakdown(
            questsCount: weekLogs.count,
            goldFromQuests: weekQuestsGold,
            bonusGold: weekBonusGold,
            totalEarned: totalEarned,
            spent: weekSpent,
            net: totalEarned + weekSpent,
            payoutStatus: payoutStatus,
            paidAmount: paidAmount
        )

        let range: Range<Date> = showAllTime
            ? (Date.distantPast ..< Date.distantFuture)
            : weekRange

        let includedLedgers = profileLedgers.filter { range.contains($0.date) }

        // Include approved logs as ledger entries for display.
        let familyName = appState.family?.id.recordName ?? ""
        let logLedgers = approvedLogs
            .filter { range.contains($0.weekOf) }
            .compactMap { log -> LedgerEntryCache? in
                guard let quest = quests.first(where: { $0.recordName == log.questRecordName }) else { return nil }
                return LedgerEntryCache(
                    recordName: "log-\(log.recordName)",
                    profileRecordName: profileName,
                    familyRecordName: familyName,
                    amount: quest.goldReward,
                    entryDescription: "Completed: \(quest.questName)",
                    date: log.completedDate,
                    source: "quest"
                )
            }

        spendingLog = (includedLedgers + logLedgers).sorted { $0.date > $1.date }
    }

    func rebuildSpendingLog(from cachedLedgers: [LedgerEntryCache], showAllTime: Bool) {
        guard let profile = appState.currentProfile else { return }
        let profileName = profile.id.recordName
        let filtered = cachedLedgers.filter { $0.profileRecordName == profileName }

        if showAllTime {
            spendingLog = filtered.sorted { $0.date > $1.date }
        } else {
            let weekRange = WeekMath.weekRange(starting: WeekMath.weekOf(date: Date()))
            spendingLog = filtered
                .filter { weekRange.contains($0.date) }
                .sorted { $0.date > $1.date }
        }
    }

    @discardableResult
    func logSpending(description: String,
                     amount: Double,
                     date: Date = Date()) async -> Bool
    {
        let trimmed = description.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else {
            errorMessage = "Describe your spending first."
            return false
        }
        guard amount.isFinite, amount > 0 else {
            errorMessage = "Enter a positive gold amount."
            return false
        }
        guard let profile = appState.currentProfile,
              let family = appState.family
        else {
            errorMessage = "No hero profile loaded."
            return false
        }

        do {
            _ = try await spending.logManual(
                profile: profile,
                family: family,
                description: trimmed,
                amount: amount,
                date: date
            )
            errorMessage = nil
            // `spending.logManual` refreshes the SwiftData cache; the
            // resulting mutation re-fires `.onChange` → `rebuildLists`. No
            // explicit `refresh()` needed here.
            return true
        } catch {
            errorMessage = "\(error)"
            return false
        }
    }

    var canLogManually: Bool {
        spending.isAvailable()
    }

    func reset() {
        balance = nil
        weeklyBreakdown = nil
        allowancePeriod = nil
        spendingLog = []
        errorMessage = nil
        isLoading = false
    }
}
