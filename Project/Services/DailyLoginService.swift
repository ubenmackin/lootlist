//
//  DailyLoginService.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import CloudKit
import Foundation
import os
import SwiftUI

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

    init(cloudKitService: any CloudKitServiceProtocol,
         cacheService: CacheService? = nil,
         appState: AppState? = nil,
         syncCoordinator: CKSyncEngineCoordinator? = nil)
    {
        self.cloudKitService = cloudKitService
        self.cacheService = cacheService
        self.appState = appState
        self.syncCoordinator = syncCoordinator
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

    /// Cross-device claim guard: the last-claim day is read from the
    /// CloudKit-backed `Profile.dailyLoginLastClaimDay`, so a reward claimed on
    /// device A is honored on device B after `CKSyncEngine` syncs. The daily
    /// cycle is now per-profile (each hero carries its own claim state on its
    /// `Profile` record), so the prior shared-device hero-switch plumbing is
    /// no longer needed — heroes are inherently isolated by record name.
    func checkDailyLoginStatus(heroProfileRecordName: String) -> DailyLoginStatus {
        let today = todayString()

        // Fail closed for a caller-supplied profile that is not the
        // authenticated active profile. Returning `.available` here would
        // make an invalid target appear claimable in a UI or shortcut.
        guard appState?.currentProfile?.id.recordName == heroProfileRecordName,
              let profile = resolvedActiveProfile()
        else { return .claimedToday }

        let lastClaim = profile.dailyLoginLastClaimDay

        if lastClaim == today {
            return .claimedToday
        }

        guard let lastClaim, let lastDate = dateFromString(lastClaim) else {
            return .available
        }

        if let yesterday = yesterday(), Calendar.current.isDate(lastDate, inSameDayAs: yesterday) {
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
        let today = todayString()

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

        // Credits gems AND upserts the profile (with all claim-state fields) +
        // enqueues the Profile record for CloudKit sync. The deterministic
        // `eventKey` (`daily-{date}`) derives an idempotent ledger ID
        // (`gem-{profile}-daily-{date}-dailyLogin`) so a cross-device re-claim
        // collapsed by sync can never credit the day's gems twice — mirroring
        // the `reward-{completionID}` RewardEvent idempotency pattern.
        try await gemService.creditGems(amount: gemsToAward, to: current, source: "dailyLogin", eventKey: "daily-\(today)", detail: "Day \(cycle) reward")

        if let active = appState.currentProfile, active.id == current.id {
            appState.currentProfile = current
        }

        soundManager.play(.dailyLogin)

        return gemsToAward
    }

    // MARK: - Date helpers

    private func todayString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.string(from: Date())
    }

    private func dateFromString(_ str: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.date(from: str)
    }

    private func yesterday() -> Date? {
        Calendar.current.date(byAdding: .day, value: -1, to: Date())
    }
}
