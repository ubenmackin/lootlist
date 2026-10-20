//
//  LedgerService+Waterfall.swift
//  LootList
//
//  Created by Ben Mackin on 10/20/26.
//

import CloudKit
import Foundation

/// Waterfall debit helpers for `LedgerService`.
///
/// Spend covers first, Short covers the shortfall with goal drawdown, Long never auto-debits.
/// Split keeps `LedgerService.swift` under the lint file-length limit while preserving
/// single-source deterministic IDs and convergent replay.
@MainActor
extension LedgerService {
    /// Bounded waterfall inputs keeping helpers under the lint parameter limit.
    struct WaterfallInputs {
        let source: String
        let profile: Profile
        let family: Family
        let request: Int64
        let trimmedDesc: String
        let normalizedLocation: String?
        let effectiveDate: Date
        let enqueueContext: String
    }

    /// WHY gap-fill: a first run may persist the Spend leg but miss the shortcover, so a partial sum mints only the remainder.
    func waterfallGapFill(
        inputs: WaterfallInputs,
        requestBaseName: String,
        requestShortName: String,
        familyName: String,
        zoneID: CKRecordZone.ID
    ) async throws -> LedgerEntry? {
        let source = inputs.source
        let profile = inputs.profile
        let family = inputs.family
        let request = inputs.request
        let trimmedDesc = inputs.trimmedDesc
        let normalizedLocation = inputs.normalizedLocation
        let effectiveDate = inputs.effectiveDate
        if let partialBase = cacheService.fetchLedgerEntry(recordName: requestBaseName, family: familyName),
           isMatchingWaterfallBase(partialBase, source: source, description: trimmedDesc, location: normalizedLocation, date: effectiveDate),
           resolveWaterfallShort(
               requestBaseName: requestBaseName,
               requestShortName: requestShortName,
               profileRecordName: profile.id.recordName,
               familyName: familyName,
               source: source,
               description: trimmedDesc,
               location: normalizedLocation,
               date: effectiveDate
           ) == nil
        {
            let storedSpend = -partialBase.amount
            if storedSpend > 0, storedSpend < request {
                let remainder = request - storedSpend
                // WHY no fork: resolved-shortcover guard proves every forked shape is absent, so the gap mints there directly.
                let gapShortName = requestShortName
                let gapEntry = LedgerEntry(
                    profile: CKRecord.Reference(recordID: profile.id, action: .none),
                    amount: -remainder,
                    description: trimmedDesc,
                    location: normalizedLocation,
                    date: effectiveDate,
                    source: source,
                    bucketKind: BucketKind.shortTermSave.rawValue,
                    family: CKRecord.Reference(recordID: family.id, action: .none),
                    id: CKRecord.ID(recordName: gapShortName, zoneID: zoneID)
                )
                // WHY atomic gap: drawdown runs before the shortcover persists so a drawdown failure never leaves a persisted leg without its reverse-FIFO haircut.
                let goalService = GoalService(
                    cloudKit: cloudKit,
                    cacheService: cacheService,
                    appState: appState,
                    syncCoordinator: syncCoordinator
                )
                _ = try await goalService.applyDrawdown(
                    amountPennies: remainder,
                    profile: profile,
                    family: family,
                    bucketKind: .shortTermSave,
                    sourceEventID: gapShortName,
                    contributionDate: effectiveDate
                )
                await persist(gapEntry, context: inputs.enqueueContext)
                return partialBase.toLedgerEntry(zoneID: zoneID)
            }
        }
        return nil
    }

    func mintWaterfallLegs(
        inputs: WaterfallInputs,
        baseID: CKRecord.ID,
        familyName: String,
        zoneID: CKRecordZone.ID
    ) async throws -> LedgerEntry {
        let source = inputs.source
        let profile = inputs.profile
        let family = inputs.family
        let request = inputs.request
        let trimmedDesc = inputs.trimmedDesc
        let normalizedLocation = inputs.normalizedLocation
        let effectiveDate = inputs.effectiveDate
        var shortcoverName = "\(baseID.recordName)-shortcover"
        let ledgers = cacheService.fetchLedgerEntries(profileRecordName: profile.id.recordName, family: familyName)
        let balances = BucketService.bucketBalances(for: ledgers, profileRecordName: profile.id.recordName)
        // WHY clamp at zero: a negative bucket never funds new spending, the remainder overdrafts instead.
        let spendAvailable = max(balances[.spend] ?? 0, 0)
        let shortAvailable = max(balances[.shortTermSave] ?? 0, 0)
        let spendPortion = min(request, spendAvailable)
        let shortPortion = min(request - spendPortion, shortAvailable)
        // WHY spend overdraft: once Short exhausts, the remainder still debits Spend negative so the spend always lands.
        let overdraft = request - spendPortion - shortPortion
        let spendLegAmount = -(spendPortion + overdraft)
        let shortLegAmount = -shortPortion
        // WHY defensive extension: a divergent shortcover occupant forks deterministically instead of overwriting.
        // WHY bucket-gated clash: shortcover legs credit Short, so wrong-bucket rows never converge.
        if shortLegAmount != 0 {
            let shortBase = shortcoverName
            var attempt = 0
            while let clash = cacheService.fetchLedgerEntry(recordName: shortcoverName, family: familyName),
                  clash.source != source
                  || clash.entryDescription != trimmedDesc
                  || !DeterministicRecordID.isSameMillisecond(clash.date, effectiveDate)
                  || clash.location != normalizedLocation
                  || clash.amount != shortLegAmount
                  || clash.bucketKind != BucketKind.shortTermSave.rawValue
            {
                let ms = Int64(effectiveDate.timeIntervalSince1970 * 1000)
                let trimmedLower = trimmedDesc.lowercased()
                let locationPart = normalizedLocation ?? ""
                // WHY unbounded convergent extension: every attempt hashes full payload so all devices agree on each fallback name.
                let payload = "\(trimmedLower)|\(ms)|\(shortPortion)|\(locationPart)|\(source)|shortcover|\(attempt)"
                shortcoverName = DeterministicRecordID.collisionExtendedName(base: shortBase, payload: payload, date: effectiveDate)
                attempt += 1
            }
        }
        var entries: [LedgerEntry] = []
        entries.reserveCapacity(2)
        if spendLegAmount != 0 {
            // WHY spend-first: the base deterministic ID carries the Spend leg so single-leg spends match historic rows.
            entries.append(LedgerEntry(
                profile: CKRecord.Reference(recordID: profile.id, action: .none),
                amount: spendLegAmount,
                description: trimmedDesc,
                location: normalizedLocation,
                date: effectiveDate,
                source: source,
                bucketKind: BucketKind.spend.rawValue,
                family: CKRecord.Reference(recordID: family.id, action: .none),
                id: baseID
            ))
        }
        if shortLegAmount != 0 {
            entries.append(LedgerEntry(
                profile: CKRecord.Reference(recordID: profile.id, action: .none),
                amount: shortLegAmount,
                description: trimmedDesc,
                location: normalizedLocation,
                date: effectiveDate,
                source: source,
                bucketKind: BucketKind.shortTermSave.rawValue,
                family: CKRecord.Reference(recordID: family.id, action: .none),
                id: CKRecord.ID(recordName: shortcoverName, zoneID: zoneID)
            ))
        }
        guard !entries.isEmpty else {
            throw SpendingServiceError.persistenceFailed
        }
        if shortPortion > 0 {
            // WHY atomic legs: Short haircut draws down before persist so a drawdown failure never leaves persisted legs without their reverse-FIFO haircut.
            let goalService = GoalService(
                cloudKit: cloudKit,
                cacheService: cacheService,
                appState: appState,
                syncCoordinator: syncCoordinator
            )
            _ = try await goalService.applyDrawdown(
                amountPennies: shortPortion,
                profile: profile,
                family: family,
                bucketKind: .shortTermSave,
                sourceEventID: shortcoverName,
                contributionDate: effectiveDate
            )
        }
        await persist(entries, context: inputs.enqueueContext)
        // WHY spend-primary: callers keep a single returned row; the Spend leg carries the spend when present.
        if let spendEntry = entries.first(where: { $0.bucketKind == BucketKind.spend.rawValue }) {
            return spendEntry
        }
        guard let fallback = entries.first else {
            throw SpendingServiceError.persistenceFailed
        }
        return fallback
    }

    /// WHY atomic receipt: waterfall legs share one base, so collect every leg plus linked drawdowns for one delete pass.
    func waterfallDeleteTargets(for entry: LedgerEntry) -> [ActiveFamilyScopeGuard.ScopedDeleteTarget] {
        let familyName = entry.family.recordID.recordName
        let profileName = entry.profile.recordID.recordName
        let zoneID = entry.id.zoneID
        let targetBase = waterfallDeleteBase(entry.id.recordName)
        // WHY profile slice: waterfall legs share profile and family, so siblings stay in one indexed fetch.
        let candidates = cacheService.fetchLedgerEntries(profileRecordName: profileName, family: familyName)
        var names = Set<String>()
        names.insert(entry.id.recordName)
        for candidate in candidates where candidate.source != LedgerSource.goal.rawValue {
            if waterfallDeleteBase(candidate.recordName) == targetBase {
                names.insert(candidate.recordName)
            }
        }
        // WHY reversal: Short shortfalls unwind goals via drawdown markers, so deleting the shortcover voids them to restore progress.
        let shortcovers = names.filter { isShortcoverName($0) }
        if !shortcovers.isEmpty {
            let markers = cacheService.fetchLedgerEntries(profileRecordName: profileName, family: familyName, recordNamePrefix: GoalService.drawdownRoot)
            for marker in markers {
                for short in shortcovers {
                    let needle = "-" + short
                    if marker.recordName.hasSuffix(needle) || marker.recordName.contains(needle + "-") {
                        names.insert(marker.recordName)
                        break
                    }
                }
            }
        }
        return names.map {
            ActiveFamilyScopeGuard.ScopedDeleteTarget(recordID: CKRecord.ID(recordName: $0, zoneID: zoneID), familyRecordName: familyName)
        }
    }

    /// WHY delegate: grouping plus delete convergence share DeterministicRecordID so forks never drift.
    func waterfallDeleteBase(_ recordName: String) -> String {
        DeterministicRecordID.waterfallBase(recordName)
    }

    /// WHY delegate: shortcover check stays single-source so forked legs never drift.
    func isShortcoverName(_ recordName: String) -> Bool {
        DeterministicRecordID.isShortcoverName(recordName)
    }
}
