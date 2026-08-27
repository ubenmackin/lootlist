//
//  DailyLoginService.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import CloudKit
import Foundation
import os
import SwiftData
import SwiftUI
import Synchronization

enum DailyLoginStatus: Equatable, Sendable {
    case available
    case claimedToday
    case streakBroken
}

@MainActor
@Observable
final class DailyLoginService {
    private let cloudKitService: any CloudKitServiceProtocol
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "DailyLogin")

    var cacheService: CacheService?
    var appState: AppState?
    var syncCoordinator: CKSyncEngineCoordinator?

    private let inFlightClaims = Mutex<Set<String>>([])

    let maxCycleDay = 7
    let rewards: [Int: Int] = [
        1: 5,
        2: 10,
        3: 15,
        4: 20,
        5: 25,
        6: 30,
        7: 50
    ]

    private var customCalendar: Calendar?

    init(cloudKitService: any CloudKitServiceProtocol,
         cacheService: CacheService? = nil,
         appState: AppState? = nil,
         syncCoordinator: CKSyncEngineCoordinator? = nil,
         calendar: Calendar? = nil)
    {
        self.cloudKitService = cloudKitService
        self.cacheService = cacheService
        self.appState = appState
        self.syncCoordinator = syncCoordinator
        self.customCalendar = calendar
    }

    // MARK: - Reactive surface (read-through to the CloudKit-backed Profile cache)

    /// To allow UI to bind or read reactively, computed properties resolve the
    /// authoritative claim state from the local cache mirror of the `Profile`
    /// record — the same store `CKSyncEngine` hydrates from CloudKit, so a
    /// claim made on another device surfaces here after sync.
    var currentCycleDay: Int {
        resolvedActiveProfile()?.dailyLoginCycleDay ?? 1
    }

    var currentStreakDays: Int {
        resolvedActiveProfile()?.dailyLoginStreakDays ?? 0
    }

    var currentLastLoginDay: String {
        resolvedActiveProfile()?.dailyLoginLastClaimDay ?? ""
    }

    var currentLastLoginHeroProfileRecordName: String {
        appState?.currentProfile?.id.recordName ?? ""
    }

    // MARK: - Profile resolution

    /// Resolves the active hero's profile from the cache (the CloudKit-mirrored
    /// read store). Falls back to `appState.currentProfile` when the cache is
    /// unavailable (cold install before the first full-sync pass).
    private func resolvedActiveProfile() -> Profile? {
        guard let appState,
              let profile = appState.currentProfile,
              appState.isAuthenticatedActiveProfile(profile)
        else {
            return nil
        }

        do {
            try ActiveFamilyScopeGuard.requireAuthenticatedActiveProfile(profile, appState: appState)
            try ActiveFamilyScopeGuard.requireActiveFamilyScope(
                familyRef: profile.family,
                zoneID: profile.id.zoneID,
                appState: appState,
                cloudKit: cloudKitService
            )
        } catch {
            logger.warning("Daily login profile scope validation failed: \(error, privacy: .private)")
            return nil
        }

        return resolvedProfile(profile) ?? profile
    }

    private func resolvedProfile(_ profile: Profile) -> Profile? {
        guard let cacheService else { return nil }
        let familyRecordName = appState?.family?.id.recordName ?? profile.family.recordID.recordName
        guard let cached = cacheService.fetchProfile(recordName: profile.id.recordName, family: familyRecordName) else { return nil }
        return cached.toProfile(zoneID: profile.id.zoneID)
    }

    // MARK: - Claim guard

    /// Checks if a daily reward has genuinely been claimed today, accounting for
    /// legacy UTC claims that may have stamped today's date on a prior calendar day.
    private func hasClaimedToday(profile: Profile) -> Bool {
        let today = todayString()
        guard profile.dailyLoginLastClaimDay == today else {
            return false
        }

        guard let cacheService else {
            return true
        }

        let profileRecordName = profile.id.recordName
        let familyRecordName = appState?.family?.id.recordName ?? profile.family.recordID.recordName

        let standardLedgerID = GemLedger.deterministicRecordID(
            profileRecordName: profileRecordName,
            eventKey: "daily-\(today)",
            source: "dailyLogin",
            zoneID: profile.id.zoneID
        )
        if let standardLedger = cacheService.fetchGemLedger(recordName: standardLedgerID.recordName, family: familyRecordName) {
            if calendar.isDateInToday(standardLedger.createdAt) {
                return true
            }
        }

        let v2LedgerID = GemLedger.deterministicRecordID(
            profileRecordName: profileRecordName,
            eventKey: "daily-\(today)-v2",
            source: "dailyLogin",
            zoneID: profile.id.zoneID
        )
        if let v2Ledger = cacheService.fetchGemLedger(recordName: v2LedgerID.recordName, family: familyRecordName) {
            if calendar.isDateInToday(v2Ledger.createdAt) {
                return true
            }
        }

        let descriptor = FetchDescriptor<GemLedgerCache>(
            predicate: #Predicate {
                $0.profileRecordName == profileRecordName &&
                    $0.familyRecordName == familyRecordName
            }
        )
        do {
            if let allLedgers = try cacheService.context?.fetch(descriptor) {
                let loginLedgers = allLedgers.filter { $0.source == "dailyLogin" }
                if loginLedgers.contains(where: { calendar.isDateInToday($0.createdAt) }) {
                    return true
                }
                if !loginLedgers.isEmpty {
                    return false
                }
            }
        } catch {
            logger.warning("Failed to fetch login ledgers from cache: \(error, privacy: .private)")
        }

        return true
    }

    /// Cross-device claim guard: the last-claim day is read from the
    /// CloudKit-backed `Profile.dailyLoginLastClaimDay`, so a reward claimed on
    /// device A is honored on device B after `CKSyncEngine` syncs. The daily
    /// cycle is now per-profile (each hero carries its own claim state on its
    /// `Profile` record), so the prior shared-device hero-switch plumbing is
    /// no longer needed — heroes are inherently isolated by record name.
    func checkDailyLoginStatus(heroProfileRecordName: String) -> DailyLoginStatus {
        // Fail closed for a caller-supplied profile that is not the
        // authenticated active profile. Returning `.available` here would
        // make an invalid target appear claimable in a UI or shortcut.
        // Single atomic read of resolvedActiveProfile avoids TOCTOU where
        // currentProfile changes between the id check and profile resolution.
        guard let profile = resolvedActiveProfile(),
              profile.id.recordName == heroProfileRecordName
        else { return .claimedToday }

        if hasClaimedToday(profile: profile) {
            return .claimedToday
        }

        let today = todayString()
        let familyRecordName = appState?.family?.id.recordName ?? profile.family.recordID.recordName
        let ledgerID = GemLedger.deterministicRecordID(
            profileRecordName: profile.id.recordName,
            eventKey: "daily-\(today)",
            source: "dailyLogin",
            zoneID: profile.id.zoneID
        )
        if let cachedLedger = cacheService?.fetchGemLedger(recordName: ledgerID.recordName, family: familyRecordName),
           calendar.isDateInToday(cachedLedger.createdAt)
        {
            return .claimedToday
        }

        guard let lastClaim = profile.dailyLoginLastClaimDay,
              let lastDate = dateFromString(lastClaim)
        else {
            return .available
        }

        // If lastClaim was marked as today (legacy UTC bug), but we established no claim occurred today:
        if lastClaim == today {
            return .available
        }

        if let yesterday = yesterday(), calendar.isDate(lastDate, inSameDayAs: yesterday) {
            return .available
        }

        return .streakBroken
    }

    // MARK: - Claim

    func claimDailyReward(for profile: Profile, gemService: GemService, soundManager: SoundManager) async throws -> Int {
        guard let appState else {
            throw ScopeViolation.noActiveProfile
        }
        try ActiveFamilyScopeGuard.requireAuthenticatedActiveProfile(profile, appState: appState)
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            familyRef: profile.family,
            zoneID: profile.id.zoneID,
            appState: appState,
            cloudKit: cloudKitService
        )

        let today = todayString()
        let claimKey = "daily-\(today)"
        let alreadyInFlight = inFlightClaims.withLock { set -> Bool in
            if set.contains(claimKey) {
                return true
            }
            set.insert(claimKey)
            return false
        }
        guard !alreadyInFlight else { return 0 }
        defer { inFlightClaims.withLock { _ = $0.remove(claimKey) } }

        let status = checkDailyLoginStatus(heroProfileRecordName: profile.id.recordName)
        guard status != .claimedToday else { return 0 }

        // Use the active session profile as the cold-cache fallback rather than
        // trusting mutable claim fields from the caller's copy.
        guard var current = resolvedActiveProfile() else {
            throw ScopeViolation.noActiveProfile
        }
        var streak = current.dailyLoginStreakDays
        var cycle = current.dailyLoginCycleDay

        if status == .streakBroken {
            if current.streakShields > 0 {
                current.streakShields -= 1
            } else {
                cycle = 1
                streak = 0
            }
        }

        let gemsToAward = rewards[cycle] ?? 5

        // Advance claim state on the Profile BEFORE crediting gems so the single
        // upsert inside `GemService.creditGems` carries both the gem increment
        // and the new streak/cycle/claim-day fields (avoids a follow-up upsert
        // overwriting the freshly-credited gemsTotal).
        streak += 1
        if streak % 7 == 0 {
            current.streakShields = min(current.streakShields + 1, 3)
        }
        current.dailyLoginStreakDays = streak
        current.dailyLoginCycleDay = (cycle % maxCycleDay) + 1
        current.dailyLoginLastClaimDay = today

        // If a prior-day legacy ledger with eventKey "daily-\(today)" exists, suffix the eventKey
        // so the new credit creates a fresh ledger rather than deduplicating against the old one.
        let familyRecordName = appState.family?.id.recordName ?? profile.family.recordID.recordName
        let legacyLedgerID = GemLedger.deterministicRecordID(
            profileRecordName: profile.id.recordName,
            eventKey: "daily-\(today)",
            source: "dailyLogin",
            zoneID: profile.id.zoneID
        )
        let hasPriorDayLedger = (cacheService?.fetchGemLedger(recordName: legacyLedgerID.recordName, family: familyRecordName))
            .map { !calendar.isDateInToday($0.createdAt) } ?? false
        let creditEventKey = hasPriorDayLedger ? "daily-\(today)-v2" : "daily-\(today)"

        // Credit gems and persist claim state using deterministic idempotent eventKey.
        let credited = try await gemService.creditGems(amount: gemsToAward, to: current, source: "dailyLogin", eventKey: creditEventKey, detail: "Day \(cycle) reward")

        if !credited {
            // Gems were already minted for today (idempotent duplicate ledger), but the profile
            // claim date was out of sync. Persist the current claim state and update appState.
            await cacheService?.upsertProfile(current)
            // WHY: owner routing uses Family.creatorUserRecordName anchor via resolvedIsOwner, not role.
            let isOwner = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState)
            let storedOwner = appState.isZoneOwner
            if isOwner != storedOwner {
                logger.warning("DailyLoginService dailyLogin isOwner corrected via creator anchor: stored=\(storedOwner) resolved=\(isOwner)")
            }
            syncCoordinator?.enqueueSave(recordID: current.id, isOwner: isOwner)
            if let active = appState.currentProfile, active.id == current.id {
                appState.currentProfile = current
            }
            return 0
        }

        // Re-resolve the authoritative profile from cache so the session
        // reflects the freshly-credited gems. Assigning the stale
        // `current` copy here would overwrite the `gems` updated inside
        // `creditGems` with the pre-credit value.
        if let active = appState.currentProfile, active.id == current.id {
            if let refreshed = resolvedProfile(current) ?? cacheService?.fetchProfile(recordName: current.id.recordName, family: current.family.recordID.recordName)?
                .toProfile(zoneID: current.id.zoneID)
            {
                appState.currentProfile = refreshed
            } else {
                appState.currentProfile = current
            }
        }

        soundManager.play(.dailyLogin)

        return gemsToAward
    }

    // MARK: - Date helpers

    private var calendar: Calendar {
        customCalendar ?? {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = .autoupdatingCurrent
            return cal
        }()
    }

    private func dayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = calendar.timeZone
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }

    private func todayString(for date: Date = Date()) -> String {
        dayFormatter().string(from: date)
    }

    private func dateFromString(_ str: String) -> Date? {
        dayFormatter().date(from: str)
    }

    private func yesterday(relativeTo date: Date = Date()) -> Date? {
        let cal = calendar
        let startOfToday = cal.startOfDay(for: date)
        return cal.date(byAdding: .day, value: -1, to: startOfToday)
    }
}
