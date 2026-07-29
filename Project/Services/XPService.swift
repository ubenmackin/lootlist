//
//  XPService.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation

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
    static let stepBase: Int = AppConstants.Experience.stepBase

    static let accessoryCadence: Int = AppConstants.Experience.accessoryCadence

    private let cloudKit: any CloudKitServicing
    let notificationService: NotificationService?
    var cacheService: CacheService?

    var toastManager: ToastManager?

    init(cloudKit: any CloudKitServicing, notificationService: NotificationService? = nil, cacheService: CacheService? = nil) {
        self.cloudKit = cloudKit
        self.notificationService = notificationService
        self.cacheService = cacheService
    }

    static func cumulativeXPForLevel(_ targetLevel: Int) -> Int {
        guard targetLevel > 1 else { return 0 }

        let tri = (targetLevel - 1) * targetLevel / 2
        return tri * stepBase
    }

    func level(forXP xp: Int) -> Int {
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
        let gained = max(amount, 0)
        let oldLevel = profile.level
        var updated = profile
        updated.xp += gained
        updated.level = level(forXP: updated.xp)

        // Snapshot the pre-mutation cached state so we can roll back on failure.
        // Mirrors FamilyService.updateProfile*: snapshot is taken BEFORE the
        // optimistic upsert so the cache can be restored to its prior value if
        // CloudKit rejects the write.
        let name = profile.id.recordName
        let snapshotProfile = cacheService?.fetchProfile(recordName: name)?.toProfile(zoneID: profile.id.zoneID)

        // Capture the last-seen server changeTag BEFORE the optimistic write so
        // we can detect a concurrent edit from another device (or background
        // since the typed Profile built via `toProfile(zoneID:)` defaults its
        // changeTag to nil (it isn't loaded from a CKRecord).
        let preMutationChangeTag = cacheService?.fetchProfile(recordName: name)?.changeTag

        // Optimistic local write first
        cacheService?.upsertProfile(updated)

        do {
            let saved = try await cloudKit.save(updated)
            cacheService?.upsertProfile(saved)

            if saved.level > oldLevel, let notificationService {
                let newLevel = saved.level
                Task {
                    try? await notificationService.send(
                        .levelUp,
                        to: saved,
                        title: "🎉 Level Up!",
                        body: "\(saved.displayName) reached Level \(newLevel)!"
                    )
                }
            }
            return saved
        } catch {
            let concurrentEditDetected = ConcurrentEditDetector.detectConcurrentEdit(
                preMutationChangeTag: preMutationChangeTag,
                fetchCurrent: { cacheService?.fetchProfile(recordName: name)?.changeTag },
                error: error
            )

            if concurrentEditDetected {
                // Concurrent edit: the server has a newer record. Discard our optimistic
                // write by re-fetching the authoritative server record, OR fall back to
                // the pre-mutation snapshot if the re-fetch also fails.
                toastManager?.show(
                    message: "Data was modified by another device. Refresh to see the latest.",
                    type: .warning
                )

                if let fresh = try? await cloudKit.fetch(Profile.self, id: profile.id) {
                    cacheService?.upsertProfile(fresh)
                    return fresh
                } else if let snapshotProfile {
                    cacheService?.upsertProfile(snapshotProfile)
                    return snapshotProfile
                } else {
                    cacheService?.invalidateProfile(recordName: name)
                    return profile
                }
            } else {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                toastManager?.show(message: message, type: .error)
                if let snapshotProfile {
                    cacheService?.upsertProfile(snapshotProfile)
                    return snapshotProfile
                }
                cacheService?.invalidateProfile(recordName: name)
                return profile
            }
        }
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

        let cycle = (level - titles.count - 1) % 4
        let magnitude = (level - titles.count - 1) / 4
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
