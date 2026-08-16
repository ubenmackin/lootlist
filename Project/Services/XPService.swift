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
    static let stepBase: Int = AppConstants.Experience.stepBase

    static let accessoryCadence: Int = AppConstants.Experience.accessoryCadence

    private let cloudKit: any CloudKitServiceProtocol
    let notificationService: NotificationService?
    var cacheService: CacheService?
    var syncCoordinator: CKSyncEngineCoordinator?

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

    static func cumulativeXPForLevel(_ targetLevel: Int) -> Int {
        guard targetLevel > 1 else { return 0 }

        let tri = (targetLevel - 1) * targetLevel / 2
        return tri * stepBase
    }

    static func level(forXP xp: Int) -> Int {
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

        let gained = max(amount, 0)
        let oldLevel = profile.level
        var updated = profile
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

        if updated.level > oldLevel, let notificationService {
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
                    logger.error("Failed to send level-up notification: \(error, privacy: .public)")
                }
            }
        }

        return updated
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

    static func title(forLevel level: Int) -> String {
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

    private static func romanNumeral(_ valueNumber: Int) -> String {
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

    func unlockedAccessories(profile: Profile) -> [String] {
        let maxUnlocked = profile.level / Self.accessoryCadence
        guard maxUnlocked >= 1 else { return [] }

        return (1 ... maxUnlocked).map { "accessory.level.\($0 * Self.accessoryCadence)" }
    }
}
