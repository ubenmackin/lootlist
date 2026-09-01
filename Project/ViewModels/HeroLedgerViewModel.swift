//
//  HeroLedgerViewModel.swift
//  LootList
//
//  Created by Ben Mackin on 8/8/26.
//

import Foundation
import Observation
import os

@MainActor
@Observable
final class HeroLedgerViewModel {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "HeroLedger")

    let heroProfile: ProfileCache
    private let spending: SpendingService
    private let appState: AppState

    private(set) var balance: Double?
    private(set) var pendingQuestGold: Double = 0.0
    private(set) var ledgerRows: [SpendingLogRow] = []
    private(set) var errorMessage: String?
    private(set) var isLoading: Bool = false

    init(heroProfile: ProfileCache, spending: SpendingService, appState: AppState) {
        self.heroProfile = heroProfile
        self.spending = spending
        self.appState = appState
    }

    func rebuildLedger(
        ledgers: [LedgerEntryCache],
        quests: [QuestCache] = [],
        completions: [QuestCompletionCache] = [],
        allowancePeriods: [AllowancePeriodCache] = [],
        scope: CalendarScope
    ) {
        balance = BucketService.ledgerBalance(for: ledgers, profileRecordName: heroProfile.recordName)

        let payoutDay = heroProfile.payoutDayEnum ?? appState.family?.payoutDay ?? .sunday
        let weekOf = WeekMath.startOfWeek(for: Date(), payoutDay: payoutDay)
        let weekRange = WeekMath.weekRange(starting: weekOf)

        let effectivePolicy = heroProfile.payoutPolicyEnum ?? appState.family?.payoutPolicy ?? .perQuest
        let hasPaidQuestThisWeek = ledgers.filter { $0.profileRecordName == heroProfile.recordName }.contains { $0.sourceEnum == .quest && weekRange.contains($0.date) }
        let currentAllowance = allowancePeriods.first {
            $0.profileRecordName == heroProfile.recordName &&
                WeekMath.startOfWeek(for: $0.weekOf, payoutDay: payoutDay) == weekOf
        }
        let payoutStatus = currentAllowance?.statusEnum
        if hasPaidQuestThisWeek || payoutStatus == .paid || effectivePolicy == .realTime {
            pendingQuestGold = 0.0
        } else {
            pendingQuestGold = GoldCalculation.netWeeklyGold(
                quests: quests,
                logs: completions,
                profileRecordName: heroProfile.recordName,
                payoutPolicy: effectivePolicy,
                weekRange: weekRange
            )
        }

        ledgerRows = LedgerRowFactory.spendingRows(from: ledgers, profileRecordName: heroProfile.recordName, scope: scope, payoutDay: payoutDay)
    }

    func deposit(description: String, amount: Double, date: Date) async -> Bool {
        guard let family = appState.family else {
            errorMessage = "No family loaded."
            return false
        }
        let zoneID = appState.resolvedFamilyZoneID()
        let profile = heroProfile.toProfile(zoneID: zoneID)

        isLoading = true
        defer { isLoading = false }

        do {
            _ = try await spending.deposit(
                profile: profile,
                family: family,
                familyRecordName: family.id.recordName,
                description: description,
                amount: amount,
                location: nil,
                date: date
            )
            errorMessage = nil
            return true
        } catch {
            logger.error("Failed to deposit: \(error, privacy: .private)")
            errorMessage = "Could not deposit. Please try again."
            return false
        }
    }

    func withdraw(description: String, amount: Double, date: Date) async -> Bool {
        guard let family = appState.family else {
            errorMessage = "No family loaded."
            return false
        }
        let zoneID = appState.resolvedFamilyZoneID()
        let profile = heroProfile.toProfile(zoneID: zoneID)

        isLoading = true
        defer { isLoading = false }

        do {
            _ = try await spending.withdraw(
                profile: profile,
                family: family,
                familyRecordName: family.id.recordName,
                description: description,
                amount: amount,
                location: nil,
                date: date
            )
            errorMessage = nil
            return true
        } catch {
            logger.error("Failed to withdraw: \(error, privacy: .private)")
            errorMessage = "Could not withdraw. Please try again."
            return false
        }
    }
}
