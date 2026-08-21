//
//  TreasuryViewModel.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import Observation
import os

struct SpendingLogRow: Identifiable, Equatable {
    let id: String
    let amount: Double
    let description: String
    let location: String?
    let date: Date
    let source: String
    let rawCache: LedgerEntryCache?

    init(id: String,
         amount: Double,
         description: String,
         location: String? = nil,
         date: Date,
         source: String,
         rawCache: LedgerEntryCache? = nil)
    {
        self.id = id
        self.amount = amount
        self.description = description
        self.location = location
        self.date = date
        self.source = source
        self.rawCache = rawCache
    }
}

@MainActor
@Observable
final class TreasuryViewModel {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "Treasury")

    private let treasury: TreasuryService

    private let spending: SpendingService

    private let appState: AppState

    private(set) var balance: Double?

    private(set) var pendingQuestGold: Double = 0.0

    private(set) var weeklyBreakdown: TreasuryService.WeeklyBreakdown?

    private(set) var allowancePeriod: AllowancePeriod?

    private(set) var spendingLog: [SpendingLogRow] = []

    private(set) var isLoading: Bool = false

    private(set) var errorMessage: String?

    init(treasury: TreasuryService,
         spending: SpendingService,
         appState: AppState)
    {
        self.treasury = treasury
        self.spending = spending
        self.appState = appState
    }

    func refreshWeeklyBreakdown() async {
        guard let profile = appState.currentProfile, let family = appState.family else { return }
        let weekOf = WeekMath.startOfWeek(for: Date(), payoutDay: profile.payoutDay ?? family.payoutDay)
        isLoading = true
        defer { isLoading = false }
        do {
            let breakdown = try await treasury.weeklyBreakdown(profile: profile, family: family, weekOf: weekOf)
            weeklyBreakdown = breakdown
            errorMessage = nil
        } catch {
            logger.warning("Failed to load weekly breakdown: \(error, privacy: .private)")
            errorMessage = "Could not load wallet totals. Pull to retry."
            if let toast = treasury.toastManager {
                toast.show(message: errorMessage ?? "Could not load wallet totals. Pull to retry.", type: .warning)
            }
        }
    }

    func rebuildLists(logs: [QuestCompletionCache], ledgers: [LedgerEntryCache], quests: [QuestCache], allowancePeriods: [AllowancePeriodCache], scope: CalendarScope) {
        guard let profile = appState.currentProfile else { return }
        let profileName = profile.id.recordName

        let profileLedgers = ledgers.filter { $0.profileRecordName == profileName }

        balance = profileLedgers.reduce(into: 0.0) { $0 += $1.amount }

        let payoutDay = profile.payoutDay ?? appState.family?.payoutDay ?? .sunday
        let weekOf = WeekMath.startOfWeek(for: Date(), payoutDay: payoutDay)
        let weekRange = WeekMath.weekRange(starting: weekOf)

        let currentAllowance = allowancePeriods.first {
            $0.profileRecordName == profileName &&
                WeekMath.startOfWeek(for: $0.weekOf, payoutDay: payoutDay) == weekOf
        }
        let payoutStatus = currentAllowance?.statusEnum
        let paidAmount = currentAllowance?.paidAmount
        if let zoneID = appState.familyZoneID {
            allowancePeriod = currentAllowance?.toAllowancePeriod(zoneID: zoneID)
        } else {
            allowancePeriod = nil
        }

        let weekLedgers = profileLedgers.filter { weekRange.contains($0.date) }
        let hasPaidQuestThisWeek = weekLedgers.contains { $0.source == "quest" }
        let weekBonusGold = weekLedgers
            .filter { $0.source == "deposit" }
            .reduce(into: 0.0) { $0 += $1.amount }
        let weekSpent = weekLedgers
            .filter { $0.source == "manual" || $0.source == "withdrawal" }
            .reduce(into: 0.0) { $0 += $1.amount }

        let profileLogs = logs.filter { $0.completerRecordName == profileName }
        let approvedLogs = profileLogs.filter {
            $0.verificationStatusEnum == .autoApproved || $0.verificationStatusEnum == .verified
        }
        let weekLogs = approvedLogs.filter { weekRange.contains($0.weekOf) || weekRange.contains($0.completedDate) }

        let weekQuestsGold = GoldCalculation.netWeeklyGold(
            quests: quests,
            logs: logs,
            profileRecordName: profileName,
            payoutPolicy: profile.payoutPolicy,
            weekRange: weekRange
        )

        let totalEarned = weekQuestsGold + weekBonusGold

        if hasPaidQuestThisWeek || payoutStatus == .paid || profile.payoutPolicy == .realTime {
            pendingQuestGold = 0.0
        } else {
            pendingQuestGold = weekQuestsGold
        }

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

        spendingLog = profileLedgers
            .filter { scope.contains($0.date, payoutDay: payoutDay) }
            .map { ledger in
                SpendingLogRow(
                    id: ledger.recordName,
                    amount: ledger.amount,
                    description: ledger.entryDescription,
                    location: ledger.location,
                    date: ledger.date,
                    source: ledger.source,
                    rawCache: ledger
                )
            }
            .sorted { $0.date > $1.date }
    }

    func rebuildSpendingLog(from cachedLedgers: [LedgerEntryCache], scope: CalendarScope) {
        guard let profile = appState.currentProfile else { return }
        let profileName = profile.id.recordName
        let payoutDay = profile.payoutDay ?? appState.family?.payoutDay ?? .sunday
        let filtered = cachedLedgers
            .filter { $0.profileRecordName == profileName }
            .filter { scope.contains($0.date, payoutDay: payoutDay) }
            .map { ledger in
                SpendingLogRow(
                    id: ledger.recordName,
                    amount: ledger.amount,
                    description: ledger.entryDescription,
                    location: ledger.location,
                    date: ledger.date,
                    source: ledger.source,
                    rawCache: ledger
                )
            }

        spendingLog = filtered.sorted { $0.date > $1.date }
    }

    func previousLocations(from cachedLedgers: [LedgerEntryCache]) -> [String] {
        var set = Set<String>()
        var list: [String] = []
        for ledger in cachedLedgers {
            guard let loc = ledger.location?.trimmingCharacters(in: .whitespacesAndNewlines), !loc.isEmpty else { continue }
            if set.insert(loc.lowercased()).inserted {
                list.append(loc)
            }
        }
        return list.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    @discardableResult
    func logSpending(description: String,
                     amount: Double,
                     location: String? = nil,
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
            errorMessage = "Enter a positive amount."
            return false
        }
        guard let profile = appState.currentProfile,
              let family = appState.family
        else {
            errorMessage = "No hero profile loaded."
            return false
        }
        let familyRecordName = family.id.recordName
        let trimmedLocation = location?.trimmingCharacters(in: .whitespacesAndNewlines)
        let locationValue = (trimmedLocation?.isEmpty == false) ? trimmedLocation : nil

        do {
            _ = try await spending.logManual(
                profile: profile,
                family: family,
                familyRecordName: familyRecordName,
                description: trimmed,
                amount: amount,
                location: locationValue,
                date: date
            )
            errorMessage = nil
            return true
        } catch {
            logger.error("Failed to log spending: \(error, privacy: .private)")
            errorMessage = "Could not log your spending. Please try again."
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
