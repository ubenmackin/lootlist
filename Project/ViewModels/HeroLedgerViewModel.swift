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
    private let logger = Logger(category: "HeroLedger")

    let heroProfile: ProfileCache
    private let spending: SpendingService
    private let appState: AppState

    private(set) var balance: Int64?
    private(set) var spendBalance: Int64 = 0
    private(set) var shortBalance: Int64 = 0
    private(set) var longBalance: Int64 = 0
    private(set) var pendingQuestGold: Int64 = 0
    private(set) var errorMessage: String?
    private(set) var isLoading: Bool = false

    /// Nil means All; non-nil filters the ledger list to that bucket's attribution.
    var selectedBucketFilter: BucketKind?
    private(set) var bucketBalances: [BucketKind: Int64] = [:]

    /// Scope-filtered groups before the bucket predicate, preserving builder running totals.
    private var scopedGroups: [TransactionGroup] = []

    init(heroProfile: ProfileCache, spending: SpendingService, appState: AppState) {
        self.heroProfile = heroProfile
        self.spending = spending
        self.appState = appState
    }

    /// WHY instance shim: views hold @Query rows but should not reimplement bucket math.
    func currentSpendBalance(from ledgers: [LedgerEntryCache]) -> Int64 {
        BucketService.resolvedSpendBalance(for: ledgers, profileRecordName: heroProfile.recordName)
    }

    func bucketBalance(_ kind: BucketKind) -> Int64 {
        bucketBalances[kind] ?? 0
    }

    /// WHY delegate: tapping the active bucket clears back to All via the shared filter.
    func toggleBucketFilter(_ kind: BucketKind) {
        selectedBucketFilter = LedgerBucketFilter.toggled(selectedBucketFilter, with: kind)
    }

    func clearBucketFilter() {
        selectedBucketFilter = nil
    }

    /// Bucket-filtered view of the scoped groups for live toggling without a rebuild.
    var filteredLedgerGroups: [TransactionGroup] {
        filteredGroups(from: scopedGroups, filter: selectedBucketFilter)
    }

    /// Single-truth alias: filtered view is the only grouping truth so stored plus computed copies cannot drift.
    var ledgerGroups: [TransactionGroup] {
        filteredLedgerGroups
    }

    func rebuildLedger(
        ledgers: [LedgerEntryCache],
        quests: [QuestCache],
        completions: [QuestCompletionCache],
        allowancePeriods: [AllowancePeriodCache],
        templates: [QuestTemplateCache],
        scope: CalendarScope
    ) {
        // WHY one helper: bucket sum is the total on every surface.
        let computedBalances = BucketService.bucketBalances(for: ledgers, profileRecordName: heroProfile.recordName)
        bucketBalances = computedBalances
        balance = BucketService.totalBalance(bucketBalances: computedBalances)
        spendBalance = computedBalances[.spend] ?? 0
        shortBalance = computedBalances[.shortTermSave] ?? 0
        longBalance = computedBalances[.longTermSave] ?? 0

        let payoutDay = heroProfile.payoutDayEnum ?? appState.family?.payoutDay ?? .sunday
        let weekOf = WeekMath.startOfWeek(for: Date(), payoutDay: payoutDay)
        let weekRange = WeekMath.weekRange(starting: weekOf)

        let effectivePolicy = heroProfile.payoutPolicyEnum ?? appState.family?.payoutPolicy ?? .perQuest
        // WHY bucket-only: nil-bucket rows are wiped residue, never paid quest gold.
        let hasPaidQuestThisWeek = ledgers.filter { $0.profileRecordName == heroProfile.recordName }
            .contains { $0.sourceEnum == .quest && BucketService.isCounted($0) && weekRange.contains($0.date) }
        let currentAllowance = allowancePeriods.first {
            $0.profileRecordName == heroProfile.recordName &&
                WeekMath.startOfWeek(for: $0.weekOf, payoutDay: payoutDay) == weekOf
        }
        let payoutStatus = currentAllowance?.statusEnum
        if hasPaidQuestThisWeek || payoutStatus == .paid || effectivePolicy == .realTime {
            pendingQuestGold = 0
        } else {
            // WHY day count wins: stale targetCount under-counts specific-days split rewards.
            let templatesByID = SpecificDaysHelper.templatesByID(templates)
            pendingQuestGold = GoldCalculation.netWeeklyPennies(
                quests: quests,
                logs: completions,
                profileRecordName: heroProfile.recordName,
                payoutPolicy: effectivePolicy,
                weekRange: weekRange,
                templatesByID: templatesByID
            )
        }

        // WHY builder-first: running totals accumulate over all entries, display filters after.
        let built = TransactionGroupBuilder.buildGroups(ledgers: ledgers, profileRecordName: heroProfile.recordName)
        scopedGroups = built.filter { scope.contains($0.date, payoutDay: payoutDay) }
    }

    private func filteredGroups(from groups: [TransactionGroup], filter: BucketKind?) -> [TransactionGroup] {
        guard let filter else { return groups }
        return groups.compactMap { adjustedGroup($0, for: filter) }
    }

    private func adjustedGroup(_ group: TransactionGroup, for filter: BucketKind) -> TransactionGroup? {
        // WHY single pattern: shared builder helper keeps match plus counted total identical on every ledger surface.
        TransactionGroupBuilder.filteredGroup(group, for: filter)
    }

    private func withLedgerAction(
        failureMessage: String,
        action: (Profile, Family) async throws -> Void
    ) async -> Bool {
        guard let family = appState.family else {
            errorMessage = "No family loaded."
            return false
        }
        let zoneID = appState.resolvedFamilyZoneID()
        let profile = heroProfile.toProfile(zoneID: zoneID)

        isLoading = true
        defer { isLoading = false }

        do {
            try await action(profile, family)
            errorMessage = nil
            return true
        } catch {
            logger.error("Ledger action failed: \(error, privacy: .private)")
            errorMessage = failureMessage
            return false
        }
    }

    func deposit(description: String, amount: Int64, date: Date) async -> Bool {
        await withLedgerAction(failureMessage: "Could not deposit. Please try again.") { profile, family in
            // WHY full-split: depositEntries sums to the exact deposit total across bucket shares.
            _ = try await spending.depositEntries(
                profile: profile,
                family: family,
                familyRecordName: family.id.recordName,
                description: description,
                amount: amount,
                location: nil,
                date: date
            )
        }
    }

    func withdraw(description: String, amount: Int64, date: Date) async -> Bool {
        await withLedgerAction(failureMessage: "Could not withdraw. Please try again.") { profile, family in
            _ = try await spending.withdraw(
                profile: profile,
                family: family,
                familyRecordName: family.id.recordName,
                description: description,
                amount: amount,
                location: nil,
                date: date
            )
        }
    }
}
