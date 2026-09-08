//
//  SpendDigestService.swift
//  LootList
//
//  Created by Ben Mackin on 9/5/26.
//

import CloudKit
import Foundation
import os
import Synchronization

/// Daily 9am spend rollup: one parent notification summarizing the last 24h of
/// hero spend debits, replacing the retired per-spend buzz.
@MainActor
final class SpendDigestService {
    private let logger = Logger(category: "SpendDigest")

    /// Local hour the rollup becomes due.
    nonisolated static let digestHour = 9
    /// Lookback window for counted spend debits.
    nonisolated static let windowInterval: TimeInterval = 24 * 60 * 60

    let cacheService: any CacheServicing
    let appState: AppState
    let notificationService: NotificationService?
    private let defaults: UserDefaults
    private let calendar: Calendar

    /// Atomic double-send guard. A plain Bool races when scenePhase .active +
    /// BGAppRefreshTask invoke concurrently: the second reads `false` mid-flight.
    private let isDelivering = Mutex<Bool>(false)

    init(
        cacheService: any CacheServicing,
        appState: AppState,
        notificationService: NotificationService? = nil,
        defaults: UserDefaults = .standard,
        calendar: Calendar = .current
    ) {
        self.cacheService = cacheService
        self.appState = appState
        self.notificationService = notificationService
        self.defaults = defaults
        self.calendar = calendar
    }

    // MARK: - Due Checks

    /// WHY wall-clock: the rollup covers the last 24h on the parent's device, so due follows the local hour, not UTC buckets.
    nonisolated static func isDue(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        calendar.component(.hour, from: now) >= digestHour
    }

    /// Next local 9am strictly after `now` — the earliest begin date for the BG refresh.
    nonisolated static func nextDigestDate(after now: Date = Date(), calendar: Calendar = .current) -> Date {
        let startOfDay = calendar.startOfDay(for: now)
        if let todayNine = calendar.date(byAdding: .hour, value: digestHour, to: startOfDay), todayNine > now {
            return todayNine
        }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? now.addingTimeInterval(windowInterval)
        return calendar.date(byAdding: .hour, value: digestHour, to: tomorrow)
            ?? tomorrow.addingTimeInterval(TimeInterval(digestHour * 3600))
    }

    /// WHY device-local stamp: one phone's rollup must not suppress another's — UserDefaults never leaves the device.
    static func digestDateKey(for familyRecordName: String) -> String {
        "spendDigestLastDate-\(familyRecordName)"
    }

    nonisolated static func dayString(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: - Summary

    /// Last-24h counted spend debits per hero, e.g. "Last 24 hours: Maya $4.50 in 2 spends, Leo $2.00 in 1 spend".
    func buildDigestSummary(now: Date = Date()) -> String? {
        guard let family = appState.family else { return nil }
        let familyName = family.id.recordName
        let heroes = cacheService.fetchProfiles(family: familyName)
            .filter { $0.roleEnum == .hero && $0.isActive }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        guard !heroes.isEmpty else { return nil }
        let windowStart = now.addingTimeInterval(-Self.windowInterval)
        var lines: [String] = []
        lines.reserveCapacity(heroes.count)
        for hero in heroes {
            // WHY all debits: withdrawal/purchase/import all debit spend but manual-only would under-report the rollup.
            let spends = cacheService.fetchLedgerEntries(profileRecordName: hero.recordName, family: familyName)
                .filter { $0.date >= windowStart && $0.date < now && $0.amount < 0 && BucketService.isCounted($0) }
            guard !spends.isEmpty else { continue }
            let total = spends.reduce(0) { $0 + abs($1.amount) }
            let noun = spends.count == 1 ? "spend" : "spends"
            lines.append("\(hero.displayName) \(CurrencyFormatter.string(pennies: total)) in \(spends.count) \(noun)")
        }
        guard !lines.isEmpty else { return nil }
        // WHY sliding label: the window spans two calendar days, so copy names the interval, not yesterday.
        return "Last 24 hours: " + lines.joined(separator: ", ")
    }

    // MARK: - Delivery

    /// Delivers the rollup once per family-day once past 9am local. Returns true iff a parent was notified.
    @discardableResult
    func maybeDeliverDailyDigest(now: Date = Date()) async -> Bool {
        // WHY device-gated: local notifications render on this device only, so a hero device must not buzz with the parent rollup.
        guard let family = appState.family,
              let currentProfile = appState.currentProfile,
              currentProfile.role.isParent
        else { return false }
        guard Self.isDue(now: now, calendar: calendar) else { return false }
        let familyName = family.id.recordName
        let today = Self.dayString(for: now, calendar: calendar)
        guard defaults.string(forKey: Self.digestDateKey(for: familyName)) != today else { return false }

        // Atomic check-and-set so concurrent callers (scenePhase .active + BGAppRefreshTask) cannot both enter.
        guard isDelivering.withLock({ flag in
            guard !flag else { return false }
            flag = true
            return true
        }) else {
            logger.debug("Spend digest already in progress. Skipping.")
            return false
        }
        defer { isDelivering.withLock { $0 = false } }

        guard defaults.string(forKey: Self.digestDateKey(for: familyName)) != today else { return false }
        guard let summary = buildDigestSummary(now: now) else {
            // WHY stamp quiet days: no spends still settles the day so every foreground doesn't rebuild an empty rollup.
            defaults.set(today, forKey: Self.digestDateKey(for: familyName))
            return false
        }
        guard let notificationService else {
            defaults.set(today, forKey: Self.digestDateKey(for: familyName))
            return false
        }
        let zoneID = appState.familyZoneID ?? family.id.zoneID
        var seen: Set<String> = []
        var parents = cacheService.fetchProfiles(family: familyName)
            .filter { $0.roleEnum?.isParent == true && $0.isActive }
            .map { $0.toProfile(zoneID: zoneID) }
            .filter { seen.insert($0.id.recordName).inserted }
        if parents.isEmpty {
            // WHY current-profile fallback: a thin profile cache must not swallow the rollup for the parent holding the device.
            parents = [currentProfile]
        }
        var delivered = false
        var failed = false
        for parent in parents {
            do {
                try await notificationService.send(.spendDailyDigest, to: parent, title: "☀️ Daily Spend Report", body: summary)
                delivered = true
            } catch {
                // WHY retry on failure: a throttled center must not consume the day's stamp, or the rollup is lost until tomorrow.
                failed = true
                logger.error("Spend digest delivery failed: \(error, privacy: .private)")
            }
        }
        if delivered || !failed {
            defaults.set(today, forKey: Self.digestDateKey(for: familyName))
        }
        return delivered
    }
}
