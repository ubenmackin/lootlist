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

    private(set) var spendingLog: [LedgerEntry] = []

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

    func refresh() async {
        guard let profile = appState.currentProfile,
              let family = appState.family
        else {
            errorMessage = "No hero profile loaded."
            return
        }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            balance = try await treasury.currentBalance(for: profile)
            weeklyBreakdown = try await treasury.weeklyBreakdown(
                profile: profile, weekOf: Date()
            )
            allowancePeriod = try await treasury.getOrCreateAllowancePeriod(
                profile: profile, weekOf: Date(), family: family
            )
            await loadSpendingLog(showAllTime: false)
        } catch {
            errorMessage = "\(error)"
        }
    }

    func rebuildLists(logs: [QuestCompletion], ledgers: [LedgerEntry], quests: [Quest], showAllTime: Bool) {
        guard let profile = appState.currentProfile else { return }

        let profileLogs = logs.filter { $0.completedBy.recordID == profile.id }
        let profileLedgers = ledgers.filter { $0.profile.recordID == profile.id }

        let approvedLogs = profileLogs.filter { $0.verificationStatus == .autoApproved || $0.verificationStatus == .verified }

        var goldFromQuests = 0.0
        for log in approvedLogs {
            if let quest = quests.first(where: { $0.id == log.quest.recordID }) {
                goldFromQuests += quest.goldReward
            }
        }

        let bonusGold = profileLedgers.filter { $0.amount > 0 }.reduce(into: 0.0) { $0 += $1.amount }
        let spent = profileLedgers.filter { $0.amount < 0 }.reduce(into: 0.0) { $0 += $1.amount }

        balance = goldFromQuests + bonusGold + spent

        let weekOf = TreasuryService.mondayOfWeek(for: Date())
        let weekRange = TreasuryService.weekRange(starting: weekOf)

        // Match the authoritative async path exactly. The two data sources use
        // DIFFERENT boundary semantics, so they must be filtered differently:
        //  - QuestCompletion: `TreasuryService.fetchQuestLogs` filters on `weekOf`
        //    with INCLUSIVE `<= weekEnding` (TreasuryService.swift:286). `weekRange`
        //    is a CLOSED interval (end = start + secondsInWeek - 1), so the bound
        //    here is `<= end` to include the final second of the week.
        //  - LedgerEntry: `TreasuryService.fetchLedgerEntries` is cache-first and
        //    filters with `dateRange.contains($0.date)` (TreasuryService.swift:249).
        //    `DateInterval.contains(_ date:)` is end-EXCLUSIVE (half-open:
        //    `start <= date && date < end`), so the cache path DROPS a ledger entry
        //    timestamped at Sunday 23:59:59. The ledger filters below must use
        //    `weekRange.contains` / `range.contains` to stay byte-for-byte aligned
        //    with the authoritative async path and avoid a flip-flop on refresh.
        let weekLogs = approvedLogs.filter { $0.weekOf >= weekRange.start && $0.weekOf <= weekRange.end }
        var weekQuestsGold = 0.0
        for log in weekLogs {
            if let quest = quests.first(where: { $0.id == log.quest.recordID }) {
                weekQuestsGold += quest.goldReward
            }
        }

        // All-or-Nothing payout gate — mirror `TreasuryService.weeklyBreakdown`
        // (TreasuryService.swift:63-68) and `FamilyDashboardViewModel.rebuildLists`
        // (:226-234): if any quest was assigned this week but not every assigned
        // quest was slain, the hero forfeits all quest gold for the week. Use
        // `weekLogs.count` since `weekLogs` is already the slain-this-week set,
        // matching the authoritative `slainCount`.
        let assignedQuests = quests.filter {
            $0.assignee.recordID == profile.id && weekRange.contains($0.weekOf)
        }
        if profile.payoutPolicy == .allOrNothing,
           !assignedQuests.isEmpty,
           weekLogs.count < assignedQuests.count
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
            net: totalEarned + weekSpent
        )

        let range: DateInterval = showAllTime
            ? DateInterval(start: .distantPast, end: .distantFuture)
            : weekRange

        let includedLedgers = profileLedgers.filter { range.contains($0.date) }

        // Include approved logs as ledger entries for display.
        let logLedgers = approvedLogs
            .filter { $0.weekOf >= range.start && $0.weekOf <= range.end }
            .compactMap { log -> LedgerEntry? in
                guard let quest = quests.first(where: { $0.id == log.quest.recordID }) else { return nil }
                let gold = quest.goldReward
                return LedgerEntry(
                    profile: CKRecord.Reference(recordID: profile.id, action: .none),
                    amount: gold,
                    description: "Completed: \(quest.displayName)",
                    date: log.completedDate,
                    family: log.family,
                    id: CKRecord.ID(recordName: "log-\(log.id.recordName)")
                )
            }

        spendingLog = (includedLedgers + logLedgers).sorted { $0.date > $1.date }
    }

    func loadSpendingLog(showAllTime: Bool) async {
        guard let profile = appState.currentProfile else {
            errorMessage = "No hero profile loaded."
            return
        }
        let range: DateInterval = showAllTime
            ? DateInterval(start: .distantPast, end: .distantFuture)
            : TreasuryService.weekRange(
                starting: TreasuryService.mondayOfWeek(for: Date())
            )
        do {
            spendingLog = try await spending.fetchTransactions(
                for: profile, in: range
            )
        } catch {
            errorMessage = "\(error)"
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
            await refresh()
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
