import Foundation
import CloudKit

struct LevelProgress: Equatable, Sendable {

    let currentLevel: Int

    let xpIntoCurrentLevel: Int

    let xpForNextLevel: Int

    let progress: Double
}

@MainActor
@Observable
final class XPService {

    static let stepBase: Int = 100

    static let accessoryCadence: Int = 5

    init(cloudKit: CloudKitService) {
        self.cloudKit = cloudKit
    }

    private let cloudKit: CloudKitService

    static func cumulativeXPForLevel(_ n: Int) -> Int {
        guard n > 1 else { return 0 }

        let tri = (n - 1) * n / 2
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

    func addXP(_ amount: Int, to profile: Profile) async throws -> Profile {
        let gained = max(amount, 0)
        var updated = profile
        updated.xp += gained
        updated.level = level(forXP: updated.xp)
        return try await cloudKit.save(updated)
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

    private static func romanNumeral(_ n: Int) -> String {
        let table: [(Int, String)] = [
            (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"),
            (100,  "C"), (90,  "XC"), (50,  "L"), (40,  "XL"),
            (10,   "X"), (9,   "IX"), (5,   "V"), (4,   "IV"),
            (1,    "I")
        ]
        var n = n
        var out = ""
        for (value, symbol) in table where n > 0 {
            while n >= value {
                out += symbol
                n -= value
            }
        }
        return out
    }

    func unlockedAccessories(profile: Profile) -> [String] {
        let maxUnlocked = profile.level / Self.accessoryCadence
        guard maxUnlocked >= 1 else { return [] }

        return (1...maxUnlocked).map { "accessory.level.\($0 * Self.accessoryCadence)" }
    }
}
