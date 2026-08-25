//
//  XPService.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import os

@MainActor
protocol CloudKitServicing {
    func save<T: CloudKitRecord>(_ model: T,
                                 in zoneID: CKRecordZone.ID?,
                                 using db: CKDatabase?) async throws -> T
    func fetch<T: CloudKitRecord>(_ type: T.Type,
                                  id: CKRecord.ID,
                                  using db: CKDatabase?) async throws -> T
}

extension CloudKitServicing {
    func save<T: CloudKitRecord>(_ model: T) async throws -> T {
        try await save(model, in: nil, using: nil)
    }

    func fetch<T: CloudKitRecord>(_ type: T.Type, id: CKRecord.ID) async throws -> T {
        try await fetch(type, id: id, using: nil)
    }
}

enum XPServiceError: Error, LocalizedError, Equatable, Sendable {
    case persistenceFailed

    var errorDescription: String? {
        "Could not update XP. Please try again."
    }
}

extension CloudKitService: CloudKitServicing {}

struct LevelProgress: Equatable, Sendable {
    let currentLevel: Int

    let xpIntoCurrentLevel: Int

    let xpForNextLevel: Int

    let progress: Double
}

@MainActor
@Observable
final class XPService {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "XPService")
    nonisolated static let stepBase: Int = AppConstants.Experience.stepBase

    nonisolated static let accessoryCadence: Int = AppConstants.Experience.accessoryCadence

    private let cloudKit: any CloudKitServiceProtocol
    let notificationService: NotificationService?
    var cacheService: CacheService?
    var syncCoordinator: CKSyncEngineCoordinator?
    var celebrationManager: CelebrationManager?

    let toastManager: ToastManager?

    var appState: AppState?

    init(
        cloudKit: any CloudKitServiceProtocol,
        notificationService: NotificationService? = nil,
        cacheService: CacheService? = nil,
        toastManager: ToastManager? = nil,
        appState: AppState? = nil,
        syncCoordinator: CKSyncEngineCoordinator? = nil
    ) {
        self.cloudKit = cloudKit
        self.notificationService = notificationService
        self.cacheService = cacheService
        self.toastManager = toastManager
        self.appState = appState
        self.syncCoordinator = syncCoordinator
    }

    nonisolated static func cumulativeXPForLevel(_ targetLevel: Int) -> Int {
        guard targetLevel > 1 else { return 0 }

        let tri = (targetLevel - 1) * targetLevel / 2
        return tri * stepBase
    }

    nonisolated static func level(forXP xp: Int) -> Int {
        guard xp > 0 else { return 1 }

        let step = Self.stepBase
        let discriminant = 1.0 + 8.0 * Double(xp) / Double(step)
        let root = (1.0 + discriminant.squareRoot()) / 2.0
        var level = Int(root.rounded(.down))

        while Self.cumulativeXPForLevel(level + 1) <= xp {
            level += 1
        }
        while level > 1, Self.cumulativeXPForLevel(level) > xp {
            level -= 1
        }

        return max(level, 1)
    }

    @discardableResult
    func addXP(_ amount: Int, to profile: Profile) async throws -> Profile {
        guard let appState, let acting = appState.currentProfile,
              acting.id == profile.id || acting.role.isParent
        else {
            throw FamilyServiceError.unauthorized
        }

        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            familyRef: profile.family,
            zoneID: profile.id.zoneID,
            appState: appState,
            cloudKit: cloudKit
        )

        // Resolve authoritative hero from cache so sequential completions that
        // both captured the same stale Profile snapshot do not lost-update XP.
        // MainActor serializes the calls but not the read snapshot — the cache
        // holds the post-first-upsert XP that the second call must base on.
        let authoritative = resolveAuthoritativeHero(profile)
        let gained = max(amount, 0)
        let oldLevel = Self.level(forXP: authoritative.xp)
        var updated = authoritative
        updated.xp += gained
        updated.level = Self.level(forXP: updated.xp)

        cacheService?.upsertProfile(updated)

        if let current = appState.currentProfile, current.id == updated.id {
            var reconciled = current
            reconciled.xp = updated.xp
            reconciled.level = updated.level
            appState.currentProfile = reconciled
        }

        let isOwner = appState.isZoneOwner
        syncCoordinator?.enqueueSave(recordID: updated.id, isOwner: isOwner)

        if updated.level > oldLevel {
            celebrationManager?.enqueueLevelUp(
                oldLevel: oldLevel,
                newLevel: updated.level,
                heroName: updated.displayName
            )

            if let notificationService {
                let newLevel = updated.level
                Task { [logger] in
                    do {
                        try await notificationService.send(
                            .levelUp,
                            to: updated,
                            title: "🎉 Level Up!",
                            body: "\(updated.displayName) reached Level \(newLevel)!"
                        )
                    } catch {
                        logger.error("Failed to send level-up notification: \(error, privacy: .private)")
                    }
                }
            }
        }

        return updated
    }

    func levelProgress(profileCache: ProfileCache) -> LevelProgress {
        let currentLevel = profileCache.level
        let levelFloor = Self.cumulativeXPForLevel(currentLevel)
        let levelCeil = Self.cumulativeXPForLevel(currentLevel + 1)
        let stepSize = levelCeil - levelFloor
        let progressIntoLevel = max(0, profileCache.xpTotal - levelFloor)
        return LevelProgress(
            currentLevel: currentLevel,
            xpIntoCurrentLevel: progressIntoLevel,
            xpForNextLevel: stepSize,
            progress: stepSize > 0 ? Double(progressIntoLevel) / Double(stepSize) : 1.0
        )
    }

    func levelProgress(profile: Profile) -> LevelProgress {
        let currentLevel = profile.level
        let levelFloor = Self.cumulativeXPForLevel(currentLevel)
        let levelCeil = Self.cumulativeXPForLevel(currentLevel + 1)
        let stepSize = levelCeil - levelFloor
        let xpInto = profile.xp - levelFloor
        let frac: Double
        if stepSize <= 0 {
            frac = 1.0
        } else {
            let raw = Double(xpInto) / Double(stepSize)
            frac = min(max(raw, 0.0), 1.0)
        }
        return LevelProgress(
            currentLevel: currentLevel,
            xpIntoCurrentLevel: xpInto,
            xpForNextLevel: stepSize,
            progress: frac
        )
    }

    nonisolated static func title(forLevel level: Int) -> String {
        let titles: [String] = [
            "Novice",
            "Apprentice",
            "Adept",
            "Veteran",
            "Champion",
            "Heroic",
            "Legendary",
            "Mythic"
        ]
        guard level >= 1 else { return titles[0] }
        if level <= titles.count {
            return titles[level - 1]
        }

        let cycle = (level - titles.count - 1) % AppConstants.Economy.prestigeTitleCycle
        let magnitude = (level - titles.count - 1) / AppConstants.Economy.prestigeTitleCycle
        let suffix = magnitude > 0 ? " \(romanNumeral(magnitude + 1))" : ""
        switch cycle {
        case 0: return "Heroic" + suffix
        case 1: return "Legendary" + suffix
        case 2: return "Mythic" + suffix
        default: return "Eternal" + suffix
        }
    }

    private nonisolated static func romanNumeral(_ valueNumber: Int) -> String {
        let table: [(Int, String)] = [
            (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"),
            (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
            (10, "X"), (9, "IX"), (5, "V"), (4, "IV"),
            (1, "I")
        ]
        var currentNumber = valueNumber
        var out = ""
        for (value, symbol) in table where currentNumber > 0 {
            while currentNumber >= value {
                out += symbol
                currentNumber -= value
            }
        }
        return out
    }

    func unlockedAccessories(profileCache: ProfileCache) -> [String] {
        let maxUnlocked = profileCache.level / Self.accessoryCadence
        guard maxUnlocked >= 1 else { return [] }
        return (1 ... maxUnlocked).map { "accessory.level.\($0 * Self.accessoryCadence)" }
    }

    func unlockedAccessories(profile: Profile) -> [String] {
        let maxUnlocked = profile.level / Self.accessoryCadence
        guard maxUnlocked >= 1 else { return [] }

        return (1 ... maxUnlocked).map { "accessory.level.\($0 * Self.accessoryCadence)" }
    }

    func streakMultiplier(forStreak days: Int) -> Double {
        switch days {
        case 0 ... 2: 1.0
        case 3 ... 6: 1.1
        case 7 ... 13: 1.25
        case 14 ... 29: 1.5
        default: 2.0
        }
    }

    func calculatedXP(baseXP: Int, streakDays: Int) -> (totalXP: Int, bonusXP: Int) {
        let multiplier = streakMultiplier(forStreak: streakDays)
        let total = Int(Double(baseXP) * multiplier)
        let bonus = total - baseXP
        return (totalXP: total, bonusXP: bonus)
    }

    /// Derives the streak multiplier from the CloudKit-backed
    /// `Profile.dailyLoginStreakDays` field rather than a device-local
    /// UserDefaults counter. UserDefaults is never used for authoritative
    /// cross-device domain data such as reward caps (ARCHITECTURE.md §2) — a
    /// user-editable `dailyLoginStreakDays` UserDefaults value could
    /// permanently inflate every quest's XP.
    func calculatedXP(baseXP: Int, profile: Profile) -> (totalXP: Int, bonusXP: Int) {
        calculatedXP(baseXP: baseXP, streakDays: profile.dailyLoginStreakDays)
    }

    /// Resolves the authoritative hero profile from the local cache so
    /// concurrent `addXP` calls that share the same stale snapshot do not
    /// lost-update. Mirrors `QuestService.resolveAuthoritativeHero(_:)` so
    /// both reward entry points read XP from the same cached source.
    private func resolveAuthoritativeHero(_ hero: Profile) -> Profile {
        let familyName = hero.family.recordID.recordName
        if let cached = cacheService?.fetchProfile(recordName: hero.id.recordName, family: familyName) {
            return cached.toProfile(zoneID: hero.id.zoneID)
        }
        return hero
    }
}
