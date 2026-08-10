//
//  TreasuryService.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import os

@MainActor
@Observable
final class TreasuryService {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "TreasuryService")
    private let cloudKit: any CloudKitServiceProtocol
    let notificationService: NotificationService?
    var cacheService: CacheService?

    /// The active session's app state, used to resolve the acting profile for
    /// privileged payout finalization. Wired by `AppDependencies`; optional so
    /// read-only callers (tests, real-time settlement) need not set it.
    var appState: AppState?

    let toastManager: ToastManager?

    init(
        cloudKit: any CloudKitServiceProtocol,
        notificationService: NotificationService? = nil,
        cacheService: CacheService? = nil,
        toastManager: ToastManager? = nil,
        appState: AppState? = nil
    ) {
        self.cloudKit = cloudKit
        self.notificationService = notificationService
        self.cacheService = cacheService
        self.appState = appState
        self.toastManager = toastManager
    }

    func currentBalance(for profile: Profile) async throws -> Double {
        let ledgerEntries = try await fetchAllLedgerEntries(profile: profile)
        return ledgerEntries.reduce(0.0) { $0 + $1.amount }
    }

    struct WeeklyBreakdown: Equatable, Sendable {
        var questsCount: Int = 0

        var goldFromQuests: Double = 0

        var bonusGold: Double = 0

        var totalEarned: Double = 0

        var spent: Double = 0

        var net: Double = 0

        var payoutStatus: PayoutStatus?
        var paidAmount: Double?
    }

    func weeklyBreakdown(profile: Profile,
                         family: Family,
                         weekOf: Date) async throws -> WeeklyBreakdown
    {
        let startOfWeek = WeekMath.startOfWeek(for: weekOf, payoutDay: profile.payoutDay ?? family.payoutDay)
        let weekRange = TreasuryService.weekRange(starting: startOfWeek)
        let logs = try await fetchQuestLogs(profile: profile,
                                            weekStarting: startOfWeek,
                                            weekEnding: weekRange.upperBound)
        var goldFromQuests = try await sumGold(for: logs, family: family)
        let completedCount = logs.filter { TreasuryService.isCompleted($0) }.count

        if profile.payoutPolicy == .allOrNothing {
            let assigned = try await fetchAssignedQuests(profile: profile, family: family, weekOf: startOfWeek)
            if !assigned.isEmpty {
                let approvedLogsScoped = logs.filter { $0.verificationStatus == .verified || $0.verificationStatus == .autoApproved }
                let fullyCompletedCount = assigned.filter { quest in
                    let questLogs = approvedLogsScoped.filter { $0.quest.recordID == quest.id }
                    return GoldCalculation.isFullyCompleted(quest: quest, approvedCount: questLogs.count)
                }.count
                if fullyCompletedCount < assigned.count {
                    goldFromQuests = 0.0
                }
            }
        }

        let ledgerEntries = try await fetchLedgerEntries(
            profile: profile, in: weekRange
        )
        let bonusGold = ledgerEntries
            .filter { $0.amount > 0 && $0.source != "quest" }
            .reduce(0.0) { $0 + $1.amount }
        let spent = ledgerEntries
            .filter { $0.amount < 0 }
            .reduce(0.0) { $0 + $1.amount }

        let totalEarned = goldFromQuests + bonusGold
        return WeeklyBreakdown(
            questsCount: completedCount,
            goldFromQuests: goldFromQuests,
            bonusGold: bonusGold,
            totalEarned: totalEarned,
            spent: spent,
            net: totalEarned + spent
        )
    }

    func getOrCreateAllowancePeriod(profile: Profile,
                                    weekOf: Date,
                                    family: Family) async throws -> AllowancePeriod
    {
        // Internal settlement helper: actor must be the target hero (self-settlement)
        // or a parent acting on the hero's behalf.
        guard let acting = appState?.currentProfile,
              acting.id == profile.id || acting.role.isParent
        else {
            throw FamilyServiceError.unauthorized
        }

        let startOfWeek = WeekMath.startOfWeek(for: weekOf, payoutDay: profile.payoutDay ?? family.payoutDay)

        let existing = try await fetchAllowancePeriod(profile: profile,
                                                      weekOf: startOfWeek)
        if let existing {
            return existing
        }

        let logs = try await fetchQuestLogs(profile: profile,
                                            weekStarting: startOfWeek,
                                            weekEnding: TreasuryService
                                                .weekRange(starting: startOfWeek).upperBound)
        let completedCount = logs.filter { TreasuryService.isCompleted($0) }.count

        let period = AllowancePeriod(
            weekOf: startOfWeek,

            profile: CKRecord.Reference(recordID: profile.id, action: .none),
            questsTotal: completedCount,
            family: CKRecord.Reference(recordID: family.id, action: .none)
        )

        // Register the optimistic window so a background sync skips this row.
        let registry = cacheService?.inFlightRegistry
        await registry?.register(period.id.recordName)

        cacheService?.upsertAllowancePeriod(period)
        // Brand-new record: there is no prior cache snapshot, so
        // `preMutationChangeTag` is `nil` and the changeTag-divergence check
        // below is effectively a no-op (returns `false`). The guard is
        // applied for consistency with the other TreasuryService update paths.
        let preMutationChangeTag: String? = nil
        do {
            let saved = try await cloudKit.save(period)
            cacheService?.upsertAllowancePeriod(saved)
            await registry?.deregister(period.id.recordName)
            return saved
        } catch {
            // Sole recovery path: invalidates the phantom row (and handles the
            // `.notFound` zombie case when the record was deleted server-side).
            await OptimisticFailureHandler.handleSaveFailure(
                recordID: period.id,
                preMutationChangeTag: preMutationChangeTag,
                snapshot: nil,
                cloudKit: cloudKit,
                toastManager: toastManager,
                fetchCurrentTag: { cacheService?.fetchAllowancePeriods(family: period.family.recordID.recordName)
                    .first(where: { $0.recordName == period.id.recordName })?.changeTag
                },
                upsert: { cacheService?.upsertAllowancePeriod($0) },
                invalidate: { _ in cacheService?.invalidateAllowancePeriod(recordName: period.id.recordName) },
                error: error
            )
            await registry?.deregister(period.id.recordName)
            throw error
        }
    }

    func updateAllowance(period: AllowancePeriod,
                         totalEarned: Double? = nil,
                         questsCompleted: Int? = nil,
                         questsTotal: Int? = nil) async throws -> AllowancePeriod
    {
        // Internal settlement helper: actor must own the period (hero
        // self-settlement) or be a parent (parent override).
        guard let acting = appState?.currentProfile,
              acting.id == period.profile.recordID || acting.role.isParent
        else {
            throw FamilyServiceError.unauthorized
        }

        var updated = period

        // Cache-first profile/family resolution mirrors QuestService's
        // settlement hot path: serve the family's cached records when fresh
        // (no CloudKit round-trip), else fall through to a single fetch.
        if let profile = try? await resolveProfile(recordID: period.profile.recordID, familyRecordName: period.family.recordID.recordName),
           let family = try? await resolveFamily(recordID: period.family.recordID)
        {
            let breakdown = try await weeklyBreakdown(profile: profile,
                                                      family: family,
                                                      weekOf: period.weekOf)
            updated.totalEarned = totalEarned ?? breakdown.totalEarned
            updated.questsCompleted = questsCompleted ?? breakdown.questsCount
        } else {
            if let totalEarned {
                updated.totalEarned = totalEarned
            }
            if let questsCompleted {
                updated.questsCompleted = questsCompleted
            }
        }
        if let questsTotal {
            updated.questsTotal = questsTotal
        }

        let name = period.id.recordName
        let snapshot = cacheService?.fetchAllowancePeriods(family: period.family.recordID.recordName).first(where: { $0.recordName == name })

        // Capture the last-seen server changeTag BEFORE the optimistic write so
        // we can detect a concurrent edit from another device (or background
        let preMutationChangeTag = snapshot?.changeTag

        // Capture an immutable value-type copy of the snapshot BEFORE the
        // optimistic write. The cache-managed `snapshot` will be mutated in
        // place by `upsertAllowancePeriod`, so reading
        // `snapshot.toAllowancePeriod(...)` later would yield the
        // *post*-mutation values. The value-type copy
        // (`AllowancePeriod` struct) is unaffected by later mutations.
        // changeTag rehydrated from cache row per toX(zoneID:), safe for use in ConcurrentEditDetector.
        let snapshotPeriod: AllowancePeriod? = snapshot?.toAllowancePeriod(zoneID: cloudKit.resolvedZoneID)

        // Register the optimistic window so a background sync skips this row.
        let registry = cacheService?.inFlightRegistry
        await registry?.register(name)

        cacheService?.upsertAllowancePeriod(updated)
        do {
            let saved = try await cloudKit.save(updated)
            cacheService?.upsertAllowancePeriod(saved)
            await registry?.deregister(name)
            return saved
        } catch {
            // Sole recovery path: re-fetches the authoritative server record on
            // a concurrent edit, else restores the pre-mutation snapshot, and
            // invalidates instead of restoring when the record was deleted
            // server-side (`.notFound` zombie prevention).
            await OptimisticFailureHandler.handleSaveFailure(
                recordID: period.id,
                preMutationChangeTag: preMutationChangeTag,
                snapshot: snapshotPeriod,
                cloudKit: cloudKit,
                toastManager: toastManager,
                fetchCurrentTag: { cacheService?.fetchAllowancePeriods(family: period.family.recordID.recordName)
                    .first(where: { $0.recordName == name })?.changeTag
                },
                upsert: { cacheService?.upsertAllowancePeriod($0) },
                invalidate: { _ in cacheService?.invalidateAllowancePeriod(recordName: name) },
                error: error
            )
            await registry?.deregister(name)
            throw error
        }
    }

    func runPayout(period: AllowancePeriod) async throws {
        // Privileged mutation: finalizing a hero's payout is parent-only.
        guard appState?.currentProfile?.role.isParent == true else {
            throw FamilyServiceError.unauthorized
        }

        var updated = period

        // Cache-first profile/family resolution so the payout finalization
        // read path skips CloudKit when the family's cache is fresh.
        // The resolved hero is kept so the ledger mint below can consult the
        // payout policy before writing a second entry for the week.
        var resolvedProfile: Profile?
        var questGoldToPayout = 0.0
        if let profile = try? await resolveProfile(recordID: period.profile.recordID, familyRecordName: period.family.recordID.recordName),
           let family = try? await resolveFamily(recordID: period.family.recordID)
        {
            resolvedProfile = profile
            let breakdown = try await weeklyBreakdown(profile: profile, family: family, weekOf: period.weekOf)
            guard breakdown.totalEarned > 0 else {
                // Do not prematurely close allowance periods for heroes with $0 earnings.
                return
            }
            updated.totalEarned = breakdown.totalEarned
            updated.questsCompleted = breakdown.questsCount
            questGoldToPayout = breakdown.goldFromQuests
        } else {
            guard (updated.totalEarned) > 0 else {
                return
            }
            questGoldToPayout = updated.totalEarned
        }

        updated.status = .paid
        updated.paidDate = Date()
        updated.paidAmount = questGoldToPayout

        let name = period.id.recordName
        let snapshot = cacheService?.fetchAllowancePeriods(family: period.family.recordID.recordName).first(where: { $0.recordName == name })

        let preMutationChangeTag = snapshot?.changeTag
        let snapshotPeriod: AllowancePeriod? = snapshot?.toAllowancePeriod(zoneID: cloudKit.resolvedZoneID)

        let registry = cacheService?.inFlightRegistry
        await registry?.register(name)

        cacheService?.upsertAllowancePeriod(updated)

        do {
            let saved = try await cloudKit.save(updated)
            cacheService?.upsertAllowancePeriod(saved)

            // Mint a quest-earnings LedgerEntry so the ledger is the single
            // source of truth for all money movement. Idempotent: the record
            // name is derived from the AllowancePeriod so re-runs are no-ops.
            //
            // Real-time heroes settle onto the ledger as each quest completes:
            // processRealTimeSettlement already wrote the week's "rt-" entry,
            // so this weekly payout is only closing the period. Minting a
            // second payout entry here would make currentBalance sum the same
            // week's quest earnings twice.
            if resolvedProfile?.payoutPolicy != .realTime {
                do {
                    try await mintPayoutLedgerEntry(
                        periodRecordName: period.id.recordName,
                        amount: updated.paidAmount ?? questGoldToPayout,
                        weekOf: period.weekOf,
                        profile: period.profile,
                        family: period.family,
                        date: updated.paidDate ?? Date()
                    )
                } catch {
                    var rollback = updated
                    rollback.status = .payoutPending
                    rollback.paidAmount = nil
                    rollback.paidDate = nil
                    if let reverted = try? await cloudKit.save(rollback) {
                        cacheService?.upsertAllowancePeriod(reverted)
                    } else {
                        cacheService?.upsertAllowancePeriod(rollback)
                    }
                    throw error
                }
            }

            if let notificationService {
                Task { [logger] in
                    do {
                        let profile = try await resolveProfile(recordID: period.profile.recordID, familyRecordName: period.family.recordID.recordName)
                        let family = try await resolveFamily(recordID: period.family.recordID)
                        try await notificationService.sendWeeklySummary(to: profile, family: family, weekOf: period.weekOf)
                    } catch {
                        logger.error("Failed to send weekly summary notification: \(error, privacy: .public)")
                    }
                }
            }
            await registry?.deregister(name)
        } catch {
            // Sole recovery path: re-fetches the authoritative server record on
            // a concurrent edit, else restores the pre-mutation snapshot, and
            // invalidates instead of restoring when the record was deleted
            // server-side (`.notFound` zombie prevention).
            await OptimisticFailureHandler.handleSaveFailure(
                recordID: period.id,
                preMutationChangeTag: preMutationChangeTag,
                snapshot: snapshotPeriod,
                cloudKit: cloudKit,
                toastManager: toastManager,
                fetchCurrentTag: { cacheService?.fetchAllowancePeriods(family: period.family.recordID.recordName)
                    .first(where: { $0.recordName == name })?.changeTag
                },
                upsert: { cacheService?.upsertAllowancePeriod($0) },
                invalidate: { _ in cacheService?.invalidateAllowancePeriod(recordName: name) },
                error: error
            )
            await registry?.deregister(name)
            throw error
        }
    }

    /// Process real-time settlement for heroes with `.realTime` payout policy.
    @discardableResult
    func processRealTimeSettlement(profile: Profile, family: Family, date: Date = Date()) async throws -> AllowancePeriod? {
        // Real-time settlement is triggered either by the hero themself (an
        // auto-approved completion) or by a parent verifying the hero's
        // completion — QuestService.applyReward launches the settlement for
        // any real-time hero with credited gold, and on a parent-verified
        // quest the acting profile is the parent, not the hero. Self-or-parent
        // guard; we return nil so the real-time Task in QuestService.applyReward
        // gracefully no-ops for an unrelated, non-parent actor (defense-in-depth
        // alongside the markComplete and verify parent-role guards).
        guard let acting = appState?.currentProfile,
              acting.id == profile.id || acting.role.isParent else { return nil }

        guard profile.payoutPolicy == .realTime else { return nil }
        let weekOf = WeekMath.startOfWeek(for: date, payoutDay: profile.payoutDay ?? family.payoutDay)
        let period = try await getOrCreateAllowancePeriod(profile: profile, weekOf: weekOf, family: family)

        let breakdown = try await weeklyBreakdown(profile: profile, family: family, weekOf: weekOf)

        // Compute quest earnings fresh from QuestCompletions since real-time
        // settlement occurs before the ledger entry is minted.
        let logs = try await fetchQuestLogs(profile: profile,
                                            weekStarting: weekOf,
                                            weekEnding: TreasuryService.weekRange(starting: weekOf).upperBound)
        let questGold = try await sumGold(for: logs, family: family)

        var updated = period
        updated.paidAmount = questGold
        updated.paidDate = Date()
        if period.paidAmount != updated.paidAmount {
            let saved = try await updateAllowance(period: updated,
                                                  totalEarned: questGold,
                                                  questsCompleted: breakdown.questsCount)

            // Upsert the real-time quest-earnings ledger entry. The record name
            // is derived from the period so each settlement upserts the same
            // row with the cumulative amount.
            await mintRealTimeLedgerEntry(
                periodRecordName: period.id.recordName,
                amount: questGold,
                weekOf: weekOf,
                profile: period.profile,
                family: CKRecord.Reference(recordID: family.id, action: .none),
                date: Date()
            )

            return saved
        }
        return period
    }

    /// Mints or skips a quest-earnings LedgerEntry for a batch/manual payout.
    /// Idempotent: uses "payout-<periodRecordName>" as the entry's record name.
    private func mintPayoutLedgerEntry(
        periodRecordName: String,
        amount: Double,
        weekOf: Date,
        profile: CKRecord.Reference,
        family: CKRecord.Reference,
        date: Date
    ) async throws {
        guard amount > 0 else { return }
        let entryRecordName = "payout-\(periodRecordName)"
        if let cache = cacheService {
            let cachedEntries = cache.fetchLedgerEntries(profileRecordName: profile.recordID.recordName, family: family.recordID.recordName)
            if cachedEntries.first(where: { $0.recordName == entryRecordName }) != nil {
                return
            }
            // Defense-in-depth: if the hero's payout policy was unresolvable
            // at payout time but real-time settlement already recorded this
            // period's earnings as an "rt-" entry, do not mint a second — it
            // would double-count the week's quest earnings in currentBalance.
            if cachedEntries.first(where: { $0.recordName == "rt-\(periodRecordName)" }) != nil {
                return
            }
        }

        // Fallback check against CloudKit when local cache is missing the entries
        let rtID = CKRecord.ID(recordName: "rt-\(periodRecordName)", zoneID: cloudKit.resolvedZoneID)
        if let rtEntry = try? await cloudKit.fetch(LedgerEntry.self, id: rtID) {
            cacheService?.upsertLedgerEntry(rtEntry)
            return
        }
        let payoutID = CKRecord.ID(recordName: entryRecordName, zoneID: cloudKit.resolvedZoneID)
        if let payoutEntry = try? await cloudKit.fetch(LedgerEntry.self, id: payoutID) {
            cacheService?.upsertLedgerEntry(payoutEntry)
            return
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let entry = LedgerEntry(
            profile: profile,
            amount: abs(amount),
            description: "Quest earnings (week of \(formatter.string(from: weekOf)))",
            date: date,
            source: "quest",
            family: family,
            id: CKRecord.ID(recordName: entryRecordName, zoneID: cloudKit.resolvedZoneID)
        )
        cacheService?.upsertLedgerEntry(entry)
        do {
            let saved = try await cloudKit.save(entry, in: cloudKit.resolvedZoneID, using: nil)
            cacheService?.upsertLedgerEntry(saved)
        } catch {
            logger.error("Failed to mint payout ledger entry: \(error, privacy: .public)")
            cacheService?.invalidateLedgerEntry(recordName: entryRecordName)
            throw error
        }
    }

    /// Upserts a real-time quest-earnings LedgerEntry. The record name is derived
    /// from the AllowancePeriod so incremental settlements update the same row.
    private func mintRealTimeLedgerEntry(
        periodRecordName: String,
        amount: Double,
        weekOf: Date,
        profile: CKRecord.Reference,
        family: CKRecord.Reference,
        date: Date
    ) async {
        guard amount > 0 else { return }
        let entryRecordName = "rt-\(periodRecordName)"
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let entry = LedgerEntry(
            profile: profile,
            amount: abs(amount),
            description: "Quest earnings — real-time (week of \(formatter.string(from: weekOf)))",
            date: date,
            source: "quest",
            family: family,
            id: CKRecord.ID(recordName: entryRecordName, zoneID: cloudKit.resolvedZoneID)
        )
        cacheService?.upsertLedgerEntry(entry)
        do {
            let saved = try await cloudKit.save(entry, in: cloudKit.resolvedZoneID, using: nil)
            cacheService?.upsertLedgerEntry(saved)
        } catch {
            logger.error("Failed to mint real-time ledger entry: \(error, privacy: .public)")
            cacheService?.invalidateLedgerEntry(recordName: entryRecordName)
        }
    }

    /// Cache-first read. Background refresh handled by SyncEngine via push notifications.
    private func fetchAllLedgerEntries(profile: Profile) async throws -> [LedgerEntry] {
        // Cache-first
        if let cache = cacheService {
            let familyName = profile.family.recordID.recordName
            let cached = cache.fetchLedgerEntries(
                profileRecordName: profile.id.recordName,
                family: familyName
            )
            if !cached.isEmpty, cache.isCacheFresh(familyRecordName: familyName, type: .ledgerEntry) {
                return cached.map { $0.toLedgerEntry(zoneID: cloudKit.resolvedZoneID) }
            }
        }
        // Fallback to CloudKit
        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(format: "profile == %@",
                                    profileRef as CVarArg)
        let entries = try await cloudKit.query(LedgerEntry.self, predicate: predicate)
        cacheService?.upsertLedgerEntries(entries)
        return entries
    }

    /// Cache-first read. Background refresh handled by SyncEngine via push notifications.
    func fetchAllowancePeriods(family: Family) async -> [AllowancePeriod] {
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let predicate = NSPredicate(format: "family == %@", familyRef)

        if let cache = cacheService {
            let familyName = family.id.recordName
            let cached = cache.fetchAllowancePeriods(family: familyName)
            if !cached.isEmpty, cache.isCacheFresh(familyRecordName: familyName, type: .allowancePeriod) {
                let zoneID = cloudKit.resolvedZoneID
                return cached.map { $0.toAllowancePeriod(zoneID: zoneID) }
            }
        }

        // Fallback to CloudKit — preserve the original sort: newest week first.
        let all = await (try? cloudKit.query(
            AllowancePeriod.self,
            predicate: predicate,
            sortDescriptors: [NSSortDescriptor(key: "weekOf", ascending: false)]
        )) ?? []
        cacheService?.upsertAllowancePeriods(all)
        return all
    }

    /// Cache-first read. Background refresh handled by SyncEngine via push notifications.
    private func fetchLedgerEntries(profile: Profile, in dateRange: Range<Date>) async throws -> [LedgerEntry] {
        if let cache = cacheService {
            let profileName = profile.id.recordName
            let familyName = profile.family.recordID.recordName
            let cached = cache.fetchLedgerEntries(profileRecordName: profileName, family: familyName)
            let filtered = cached.filter { dateRange.contains($0.date) }
            if !filtered.isEmpty, cache.isCacheFresh(familyRecordName: familyName, type: .ledgerEntry) {
                return filtered.map { $0.toLedgerEntry(zoneID: cloudKit.resolvedZoneID) }
            }
        }

        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(
            format: "profile == %@ AND date >= %@ AND date < %@",
            profileRef as CVarArg,
            dateRange.lowerBound as CVarArg,
            dateRange.upperBound as CVarArg
        )
        let entries = try await cloudKit.query(LedgerEntry.self, predicate: predicate)
        cacheService?.upsertLedgerEntries(entries)
        return entries
    }

    /// Cache-first read. Background refresh handled by SyncEngine via push notifications.
    private func fetchQuestLogs(profile: Profile,
                                weekStarting: Date,
                                weekEnding: Date) async throws -> [QuestCompletion]
    {
        if let cache = cacheService {
            let profileName = profile.id.recordName
            let familyName = profile.family.recordID.recordName
            let cached = cache.fetchQuestCompletions(family: familyName)
                .filter { $0.completerRecordName == profileName && $0.weekOf >= weekStarting && $0.weekOf < weekEnding }
            if !cached.isEmpty, cache.isCacheFresh(familyRecordName: familyName, type: .questCompletion) {
                let zoneID = cloudKit.resolvedZoneID
                return cached.map { $0.toQuestCompletion(zoneID: zoneID) }
            }
        }

        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(format: "completedBy == %@", profileRef as CVarArg)
        let all = try await cloudKit.query(QuestCompletion.self, predicate: predicate)
        cacheService?.upsertQuestCompletions(all)
        return all.filter { $0.weekOf >= weekStarting && $0.weekOf < weekEnding }
    }

    /// Cache-first read. Background refresh handled by SyncEngine via push notifications.
    private func fetchAssignedQuests(profile: Profile, family: Family, weekOf: Date) async throws -> [Quest] {
        let effectivePayoutDay = profile.payoutDay ?? family.payoutDay
        let startOfWeek = WeekMath.startOfWeek(for: weekOf, payoutDay: effectivePayoutDay)

        let range = TreasuryService.weekRange(starting: startOfWeek)

        if let cache = cacheService {
            let profileName = profile.id.recordName
            let familyName = profile.family.recordID.recordName
            let cached = cache.fetchQuests(family: familyName)
                .filter { $0.assigneeRecordName == profileName && range.contains($0.weekOf) }
            if !cached.isEmpty, cache.isCacheFresh(familyRecordName: familyName, type: .quest) {
                let zoneID = cloudKit.resolvedZoneID
                return cached.map { $0.toQuest(zoneID: zoneID) }
            }
        }

        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(format: "assignee == %@", profileRef as CVarArg)
        let all = try await cloudKit.query(Quest.self, predicate: predicate)
        cacheService?.upsertQuests(all)
        return all.filter { range.contains($0.weekOf) }
    }

    /// Cache-first read. Background refresh handled by SyncEngine via push notifications.
    private func fetchAllowancePeriod(profile: Profile,
                                      weekOf: Date) async throws -> AllowancePeriod?
    {
        if let cache = cacheService {
            let profileName = profile.id.recordName
            let familyName = profile.family.recordID.recordName
            let cached = cache.fetchAllowancePeriods(profileRecordName: profileName, family: familyName)
                .first { Calendar.iso8601UTC.isDate($0.weekOf, inSameDayAs: weekOf) }
            if let cached, cache.isCacheFresh(familyRecordName: familyName, type: .allowancePeriod) {
                return cached.toAllowancePeriod(zoneID: cloudKit.resolvedZoneID)
            }
        }

        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(
            format: "profile == %@ AND weekOf == %@",
            profileRef as CVarArg,
            weekOf as CVarArg
        )
        let periods = try await cloudKit.query(AllowancePeriod.self,
                                               predicate: predicate)
        cacheService?.upsertAllowancePeriods(periods)
        return periods.first
    }

    /// Cache-first profile read for the settlement/payout paths. Serves the
    /// profile from the family's cached rows when that family's profile
    /// freshness stamp is set, else falls through to a single CloudKit fetch.
    /// The freshness gate is keyed by the family (profiles are family-scoped
    /// cache rows), while the lookup uses the profile's own record name.
    private func resolveProfile(recordID: CKRecord.ID, familyRecordName: String) async throws -> Profile {
        if let cache = cacheService,
           cache.isCacheFresh(familyRecordName: familyRecordName, type: .profile),
           let cached = cache.fetchProfile(recordName: recordID.recordName)
        {
            return cached.toProfile(zoneID: cloudKit.resolvedZoneID)
        }
        return try await cloudKit.fetch(Profile.self, id: recordID)
    }

    /// Cache-first family read for the settlement/payout paths. Serves the
    /// family's cached record when its freshness stamp is set, else falls
    /// through to a single CloudKit fetch.
    private func resolveFamily(recordID: CKRecord.ID) async throws -> Family {
        if let cache = cacheService,
           cache.isCacheFresh(familyRecordName: recordID.recordName, type: .family),
           let cached = cache.fetchFamily(recordName: recordID.recordName)
        {
            return cached.toFamily(zoneID: cloudKit.resolvedZoneID)
        }
        return try await cloudKit.fetch(Family.self, id: recordID)
    }

    private func sumGold(for logs: [QuestCompletion], family: Family? = nil) async throws -> Double {
        await GoldCalculation.totalCredit(
            logs: logs,
            cacheService: cacheService,
            cloudKit: cloudKit,
            family: family
        )
    }

    private static func isCompleted(_ log: QuestCompletion) -> Bool {
        log.verificationStatus == .verified
            || log.verificationStatus == .autoApproved
    }

    static func weekRange(starting monday: Date) -> Range<Date> {
        WeekMath.weekRange(starting: monday)
    }

    static func mondayOfWeek(for date: Date) -> Date {
        WeekMath.mondayOfWeek(for: date)
    }
}
