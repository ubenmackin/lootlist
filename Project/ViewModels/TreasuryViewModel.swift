//
//  TreasuryViewModel.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation
import Observation
import os

struct SpendingLogRow: Identifiable, Equatable {
    let id: String
    /// Whole pennies (signed).
    let amount: Int64
    let description: String
    let location: String?
    let date: Date
    let source: String
    let rawCache: LedgerEntryCache?

    init(id: String,
         amount: Int64,
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

    var formattedAmount: String {
        CurrencyFormatter.string(pennies: amount)
    }

    var bucketKind: String? {
        rawCache?.bucketKind
    }

    var bucketKindEnum: BucketKind? {
        bucketKind.flatMap { BucketKind(rawValue: $0) }
    }
}

@MainActor
@Observable
final class TreasuryViewModel {
    /// Typed treasury failures surfaced alongside `errorMessage` so callers can
    /// branch without parsing copy. Messages stay stable for existing views.
    enum TreasuryError: Error, Equatable, Sendable, LocalizedError {
        case missingDescription
        case invalidAmount
        case missingProfile
        case logFailed

        var errorDescription: String? {
            switch self {
            case .missingDescription:
                "Describe your spending first."
            case .invalidAmount:
                "Enter a positive amount."
            case .missingProfile:
                "No hero profile loaded."
            case .logFailed:
                "Could not log your spending. Please try again."
            }
        }
    }

    private let logger = Logger(category: "Treasury")

    private let treasury: TreasuryService

    private let spending: SpendingService

    private let appState: AppState

    private(set) var balance: Int64?

    private(set) var spendBalance: Int64 = 0

    private(set) var pendingQuestGold: Int64 = 0

    private(set) var weeklyBreakdown: TreasuryService.WeeklyBreakdown?

    private(set) var allowancePeriod: AllowancePeriodCache?

    private(set) var spendingLog: [SpendingLogRow] = []

    private(set) var isLoading: Bool = false

    private(set) var errorMessage: String?

    /// Typed counterpart to `errorMessage` for branchable error handling.
    private(set) var lastError: TreasuryError?

    private func setError(_ error: TreasuryError) {
        lastError = error
        errorMessage = error.localizedDescription
    }

    private func clearError() {
        lastError = nil
        errorMessage = nil
    }

    /// WHY snapshot: coordinator-owned sync health rides the view model so inline footnotes render without CloudKit imports.
    private(set) var pendingUploadCount: Int = 0

    private(set) var lastSyncedAt: Date?

    /// WHY first-pass flag: separates skeleton (never rebuilt) from empty (rebuilt with zero rows).
    private(set) var hasLoadedOnce: Bool = false

    init(treasury: TreasuryService,
         spending: SpendingService,
         appState: AppState)
    {
        self.treasury = treasury
        self.spending = spending
        self.appState = appState
    }

    // MARK: - Helpers

    private var resolvedPayoutDay: PayoutDay {
        appState.resolvedPayoutDay
    }

    /// WHY instance shim: views hold @Query rows but should not reimplement bucket math.
    func currentSpendBalance(from ledgers: [LedgerEntryCache], viewerRow: ProfileCache? = nil) -> Int64 {
        // WHY row-first: balance identity must mirror @Query rows so session edits never disagree with gating.
        guard let profileName = viewerRow?.recordName ?? appState.currentProfile?.id.recordName else { return 0 }
        return BucketService.resolvedSpendBalance(for: ledgers, profileRecordName: profileName)
    }

    // MARK: - Sync Snapshot (prod-safe subset mirror)

    /// WHY push not pull: views own the coordinator environment so the model stays CloudKit-free.
    func applySyncSnapshot(pendingUploadCount: Int, lastSyncedAt: Date?) {
        self.pendingUploadCount = pendingUploadCount
        self.lastSyncedAt = lastSyncedAt
    }

    var hasPendingUploads: Bool {
        pendingUploadCount > 0
    }

    // MARK: - Weekly Breakdown (cache-only)

    func rebuildLists(
        logs: [QuestCompletionCache],
        ledgers: [LedgerEntryCache],
        quests: [QuestCache],
        allowancePeriods: [AllowancePeriodCache],
        scope: CalendarScope,
        templates: [QuestTemplateCache],
        viewerRow: ProfileCache? = nil,
        familyRow: FamilyCache? = nil
    ) {
        // WHY row-first: identity must mirror @Query rows so treasury math never disagrees with gating.
        guard let profileName = viewerRow?.recordName ?? appState.currentProfile?.id.recordName else { return }

        let profileLedgers = ledgers.filter { $0.profileRecordName == profileName }

        // WHY one helper: bucket sum is the total on every surface.
        balance = BucketService.totalBalance(for: ledgers, profileRecordName: profileName)
        spendBalance = BucketService.resolvedSpendBalance(for: ledgers, profileRecordName: profileName)

        let payoutDay: PayoutDay = if viewerRow != nil || familyRow != nil {
            PayoutDayResolver.resolved(for: viewerRow, family: familyRow)
        } else {
            resolvedPayoutDay
        }
        let weekOf = WeekMath.startOfWeek(for: Date(), payoutDay: payoutDay)
        let weekRange = WeekMath.weekRange(starting: weekOf)

        let currentAllowance = allowancePeriods.first {
            $0.profileRecordName == profileName &&
                WeekMath.startOfWeek(for: $0.weekOf, payoutDay: payoutDay) == weekOf
        }
        // WHY cache-only: treasury renders the queried row so domain conversion stays at the service boundary.
        allowancePeriod = currentAllowance
        let payoutStatus = currentAllowance?.statusEnum
        let paidAmount = currentAllowance?.paidAmount

        let weekLedgers = profileLedgers.filter { weekRange.contains($0.date) }
        // WHY bucket-only: nil-bucket rows are wiped residue, never paid quest gold.
        let hasPaidQuestThisWeek = weekLedgers.contains { $0.sourceEnum == .quest && BucketService.isCounted($0) }
        // WHY single-count: goal markers reuse already-counted funds and transfers move between buckets.
        let weekBonusGold = weekLedgers
            .filter { BucketService.isBonusCounted($0) }
            .reduce(into: Int64(0)) { $0 += $1.amount }
        let weekSpent = weekLedgers
            // WHY counted only: nil-bucket residue would count in spent but not ledgerBalance.
            .filter { $0.amount < 0 && BucketService.isCounted($0) }
            .reduce(into: Int64(0)) { $0 += $1.amount }

        let profileLogs = logs.filter { $0.completerRecordName == profileName }
        let approvedLogs = profileLogs.filter {
            $0.verificationStatusEnum == .autoApproved || $0.verificationStatusEnum == .verified
        }
        let weekLogs = approvedLogs.filter { weekRange.contains($0.weekOf) || weekRange.contains($0.completedDate) }

        // WHY row-first: payout policy must mirror @Query rows so pending math never disagrees with gating.
        let effectivePolicy: PayoutPolicy = if viewerRow != nil || familyRow != nil {
            viewerRow?.payoutPolicyEnum ?? familyRow?.payoutPolicyEnum ?? .perQuest
        } else {
            appState.currentProfile?.payoutPolicy ?? appState.family?.payoutPolicy ?? .perQuest
        }
        // WHY day count wins: stale targetCount under-counts specific-days split rewards.
        let templatesByID = SpecificDaysHelper.templatesByID(templates)
        let weekQuestsGold = GoldCalculation.netWeeklyPennies(
            quests: quests,
            logs: logs,
            profileRecordName: profileName,
            payoutPolicy: effectivePolicy,
            weekRange: weekRange,
            templatesByID: templatesByID
        )

        let totalEarned = weekQuestsGold + weekBonusGold

        if hasPaidQuestThisWeek || payoutStatus == .paid || effectivePolicy == .realTime {
            pendingQuestGold = 0
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

        spendingLog = LedgerRowFactory.spendingRows(from: ledgers, profileRecordName: profileName, scope: scope, payoutDay: payoutDay)
        // WHY late flag: rebuild completed so skeleton must yield to empty-or-content on next render.
        hasLoadedOnce = true
    }

    func rebuildSpendingLog(from cachedLedgers: [LedgerEntryCache], scope: CalendarScope, viewerRow: ProfileCache? = nil, familyRow: FamilyCache? = nil) {
        // WHY row-first: identity must mirror @Query rows so spending math never disagrees with gating.
        guard let profileName = viewerRow?.recordName ?? appState.currentProfile?.id.recordName else { return }
        let payoutDay: PayoutDay = if viewerRow != nil || familyRow != nil {
            PayoutDayResolver.resolved(for: viewerRow, family: familyRow)
        } else {
            resolvedPayoutDay
        }
        spendBalance = BucketService.resolvedSpendBalance(for: cachedLedgers, profileRecordName: profileName)
        spendingLog = LedgerRowFactory.spendingRows(from: cachedLedgers, profileRecordName: profileName, scope: scope, payoutDay: payoutDay)
        // WHY late flag: spending-only rebuilds also retire the skeleton.
        hasLoadedOnce = true
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
                     amount: Int64,
                     location: String? = nil,
                     date: Date = Date()) async -> Bool
    {
        let trimmed = description.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else {
            setError(.missingDescription)
            return false
        }
        guard amount > 0 else {
            setError(.invalidAmount)
            return false
        }
        guard let profile = appState.currentProfile,
              let family = appState.family
        else {
            setError(.missingProfile)
            return false
        }
        let familyRecordName = family.id.recordName
        let trimmedLocation = location?.trimmingCharacters(in: .whitespacesAndNewlines)
        let locationValue = trimmedLocation.flatMap { $0.isEmpty ? nil : $0 }

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
            clearError()
            return true
        } catch {
            logger.error("Failed to log spending: \(error, privacy: .private)")
            setError(.logFailed)
            return false
        }
    }

    var canLogManually: Bool {
        spending.isAvailable()
    }

    func reset() {
        balance = nil
        spendBalance = 0
        weeklyBreakdown = nil
        allowancePeriod = nil
        spendingLog = []
        clearError()
        isLoading = false
        pendingUploadCount = 0
        lastSyncedAt = nil
        hasLoadedOnce = false
    }
}
