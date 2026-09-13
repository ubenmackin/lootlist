//
//  TreasuryService+PayoutSettlement.swift
//  LootList
//
//  Created by Ben Mackin on 9/13/26.
//

import CloudKit
import Foundation
import os

@MainActor
extension TreasuryService {
    func settleDuePayouts(
        heroRows: [ProfileCache],
        familyRow: FamilyCache?,
        now: Date = Date(),
        allowEarlyCurrentWeek: Bool
    ) async -> (settled: Int, failed: [String]) {
        guard let familyRow else { return (0, []) }
        let baseZoneID = appState.resolvedFamilyZoneID(fallbackRecord: heroRows.first)
        guard let family = await settlementFamily(recordName: familyRow.recordName, zoneID: baseZoneID) else {
            return (0, Array(Set(heroRows.map(\.displayName))))
        }
        var settled = 0
        var failedHeroes = Set<String>()
        for heroRow in heroRows {
            let outcome = await settleHero(
                heroRow,
                family: family,
                baseZoneID: baseZoneID,
                now: now,
                allowEarlyCurrentWeek: allowEarlyCurrentWeek
            )
            settled += outcome.settled
            if let failedName = outcome.failedName {
                failedHeroes.insert(failedName)
            }
        }
        return (settled, Array(failedHeroes))
    }

    private func settlementFamily(recordName: String, zoneID: CKRecordZone.ID) async -> Family? {
        do {
            return try await resolveFamily(recordID: CKRecord.ID(recordName: recordName, zoneID: zoneID))
        } catch {
            logger.warning("Payout settlement aborted: family unresolved \(error, privacy: .private)")
            return nil
        }
    }

    private func settleHero(
        _ heroRow: ProfileCache,
        family: Family,
        baseZoneID: CKRecordZone.ID,
        now: Date,
        allowEarlyCurrentWeek: Bool
    ) async -> (settled: Int, failedName: String?) {
        guard heroRow.roleEnum == .hero, heroRow.isActive else { return (0, nil) }
        let hero: Profile
        do {
            let heroID = CKRecord.ID(recordName: heroRow.recordName, zoneID: heroRow.validatedZoneID(requestedZoneID: baseZoneID))
            hero = try await resolveProfile(recordID: heroID, familyRecordName: heroRow.familyRecordName)
        } catch {
            return (0, heroRow.displayName)
        }
        guard effectivePayoutPolicy(for: hero, family: family) != .realTime else { return (0, nil) }
        let slots = dueWeeks(for: hero, family: family, now: now, allowEarlyCurrentWeek: allowEarlyCurrentWeek)
        var settled = 0
        var failedName: String?
        for slot in slots {
            do {
                if try await settleWeek(hero: hero, family: family, weekOf: slot.weekOf, isCurrent: slot.isCurrent) {
                    settled += 1
                }
            } catch {
                logger.error("Payout settlement failed for \(hero.displayName, privacy: .private): \(error, privacy: .private)")
                failedName = hero.displayName
            }
        }
        return (settled, failedName)
    }

    private func dueWeeks(for hero: Profile, family: Family, now: Date, allowEarlyCurrentWeek: Bool) -> [(weekOf: Date, isCurrent: Bool)] {
        let payoutDay = hero.payoutDay ?? family.payoutDay
        let currentWeekStart = WeekMath.startOfWeek(for: now, payoutDay: payoutDay)
        let previousWeekStart = WeekMath.weekStart(byAddingWeeks: -1, to: currentWeekStart)
        let weeks: [(weekOf: Date, isCurrent: Bool)] = [(currentWeekStart, true), (previousWeekStart, false)]
        return weeks.filter { weekOf, isCurrent in
            now >= WeekMath.weekRange(starting: weekOf).upperBound || (allowEarlyCurrentWeek && isCurrent)
        }
    }

    private func settleWeek(hero: Profile, family: Family, weekOf: Date, isCurrent: Bool) async throws -> Bool {
        if isCurrent {
            return try await settleCurrentWeek(hero: hero, family: family, weekOf: weekOf)
        }
        if let existing = try await fetchAllowancePeriod(profile: hero, weekOf: weekOf) {
            guard existing.status != .paid else { return false }
            // WHY empty stays open: settling zero earnings would close the period with paid-zero.
            let breakdown = try await weeklyBreakdown(profile: hero, family: family, weekOf: weekOf)
            guard breakdown.totalEarned > 0 else { return false }
            try await runPayout(period: existing)
            return true
        }
        return try await settleCurrentWeek(hero: hero, family: family, weekOf: weekOf)
    }

    private func settleCurrentWeek(hero: Profile, family: Family, weekOf: Date) async throws -> Bool {
        let breakdown = try await weeklyBreakdown(profile: hero, family: family, weekOf: weekOf)
        guard breakdown.totalEarned > 0 else { return false }
        let period = try await getOrCreateAllowancePeriod(profile: hero, weekOf: weekOf, family: family)
        guard period.status != .paid else { return false }
        try await runPayout(period: period)
        return true
    }
}
