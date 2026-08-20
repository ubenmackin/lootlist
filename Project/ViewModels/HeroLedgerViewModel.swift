//
//  HeroLedgerViewModel.swift
//  LootList
//
//  Created by Ben Mackin on 8/8/26.
//

import CloudKit
import Foundation
import Observation
import os

@MainActor
@Observable
final class HeroLedgerViewModel {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "HeroLedger")

    let heroProfile: ProfileCache
    private let spending: any SpendingService
    private let appState: AppState

    private(set) var balance: Double?
    private(set) var pendingQuestGold: Double = 0.0
    private(set) var ledgerRows: [SpendingLogRow] = []
    private(set) var errorMessage: String?
    private(set) var isLoading: Bool = false

    init(heroProfile: ProfileCache, spending: any SpendingService, appState: AppState) {
        self.heroProfile = heroProfile
        self.spending = spending
        self.appState = appState
    }

    // MARK: - Ledger

    func rebuildLedger(
        ledgers: [LedgerEntryCache],
        quests: [QuestCache] = [],
        completions: [QuestCompletionCache] = [],
        scope: CalendarScope
    ) {
        let heroLedgers = ledgers.filter { $0.profileRecordName == heroProfile.recordName }
        balance = heroLedgers.reduce(0.0) { $0 + $1.amount }

        let payoutDay = heroProfile.payoutDayEnum ?? appState.family?.payoutDay ?? .sunday
        let weekRange = WeekMath.weekRange(starting: WeekMath.startOfWeek(for: Date(), payoutDay: payoutDay))

        let hasPaidQuestThisWeek = heroLedgers.contains { $0.source == "quest" && weekRange.contains($0.date) }
        if hasPaidQuestThisWeek || heroProfile.payoutPolicyEnum == .realTime {
            pendingQuestGold = 0.0
        } else {
            pendingQuestGold = GoldCalculation.netWeeklyGold(
                quests: quests,
                logs: completions,
                profileRecordName: heroProfile.recordName,
                payoutPolicy: heroProfile.payoutPolicyEnum,
                weekRange: weekRange
            )
        }

        let filtered = heroLedgers.filter { scope.contains($0.date, payoutDay: payoutDay) }

        ledgerRows = filtered.map { ledger in
            SpendingLogRow(
                id: ledger.recordName,
                amount: ledger.amount,
                description: ledger.entryDescription,
                location: ledger.location,
                date: ledger.date,
                source: ledger.source,
                rawCache: ledger
            )
        }.sorted { $0.date > $1.date }
    }

    // MARK: - Mutations

    func deposit(description: String, amount: Double, date: Date) async -> Bool {
        guard let family = appState.family else {
            errorMessage = "No family loaded."
            return false
        }
        // Fallback to family's zone when `familyZoneID` has not yet propagated for a new hero.
        let zoneID = appState.familyZoneID ?? family.id.zoneID
        let profile = heroProfile.toProfile(zoneID: zoneID)

        isLoading = true
        defer { isLoading = false }

        do {
            // Direct dispatch to concrete ManualSpendingService when possible avoids
            // existential witness fallback that surfaces as `unsupported` for a
            // brand-new hero with no ledger history.
            if let manual = spending as? ManualSpendingService {
                _ = try await manual.deposit(
                    profile: profile,
                    family: family,
                    familyRecordName: family.id.recordName,
                    description: description,
                    amount: amount,
                    location: nil,
                    date: date
                )
            } else {
                _ = try await spending.deposit(
                    profile: profile,
                    family: family,
                    familyRecordName: family.id.recordName,
                    description: description,
                    amount: amount,
                    date: date
                )
            }
            errorMessage = nil
            return true
        } catch let error as SpendingServiceError where error == .unsupported {
            logger.warning("Deposit hit unsupported via existential, retrying with cache fallback for new hero")
            // Fallback for read-only providers or witness mis-dispatch: write
            // directly to the local cache and enqueue, preserving offline-first
            // success for seeding deposits.
            if let cache = appState.cacheService {
                let entry = LedgerEntry(
                    profile: CKRecord.Reference(recordID: profile.id, action: .none),
                    amount: abs(amount),
                    description: description,
                    date: date,
                    source: "deposit",
                    family: CKRecord.Reference(recordID: family.id, action: .none),
                    id: CKRecord.ID(recordName: "deposit-\(profile.id.recordName)-\(family.id.recordName)-\(Int(date.timeIntervalSince1970 * 1000))", zoneID: family.id.zoneID)
                )
                cache.upsertLedgerEntry(entry)
                if let manual = spending as? ManualSpendingService {
                    manual.syncCoordinator?.enqueueSave(recordID: entry.id, isOwner: appState.isZoneOwner)
                }
                errorMessage = nil
                return true
            }
            logger.error("Failed to deposit: \(error, privacy: .private)")
            errorMessage = "Could not deposit. Please try again."
            return false
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
        // Fallback to family's zone when `familyZoneID` has not yet propagated for a new hero.
        let zoneID = appState.familyZoneID ?? family.id.zoneID
        let profile = heroProfile.toProfile(zoneID: zoneID)

        isLoading = true
        defer { isLoading = false }

        do {
            if let manual = spending as? ManualSpendingService {
                _ = try await manual.withdraw(
                    profile: profile,
                    family: family,
                    familyRecordName: family.id.recordName,
                    description: description,
                    amount: amount,
                    location: nil,
                    date: date
                )
            } else {
                _ = try await spending.withdraw(
                    profile: profile,
                    family: family,
                    familyRecordName: family.id.recordName,
                    description: description,
                    amount: amount,
                    date: date
                )
            }
            errorMessage = nil
            return true
        } catch let error as SpendingServiceError where error == .unsupported {
            logger.warning("Withdraw hit unsupported via existential, retrying with cache fallback for new hero")
            if let cache = appState.cacheService {
                let entry = LedgerEntry(
                    profile: CKRecord.Reference(recordID: profile.id, action: .none),
                    amount: -abs(amount),
                    description: description,
                    date: date,
                    source: "withdrawal",
                    family: CKRecord.Reference(recordID: family.id, action: .none),
                    id: CKRecord.ID(recordName: "withdrawal-\(profile.id.recordName)-\(family.id.recordName)-\(Int(date.timeIntervalSince1970 * 1000))", zoneID: family.id.zoneID)
                )
                cache.upsertLedgerEntry(entry)
                if let manual = spending as? ManualSpendingService {
                    manual.syncCoordinator?.enqueueSave(recordID: entry.id, isOwner: appState.isZoneOwner)
                }
                errorMessage = nil
                return true
            }
            logger.error("Failed to withdraw: \(error, privacy: .private)")
            errorMessage = "Could not withdraw. Please try again."
            return false
        } catch {
            logger.error("Failed to withdraw: \(error, privacy: .private)")
            errorMessage = "Could not withdraw. Please try again."
            return false
        }
    }
}
