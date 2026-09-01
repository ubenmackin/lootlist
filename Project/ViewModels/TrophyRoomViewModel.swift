//
//  TrophyRoomViewModel.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation

@MainActor
@Observable
final class TrophyRoomViewModel {
    init(achievementService: AchievementService,
         xpService: XPService,
         appState: AppState)
    {
        self.achievementService = achievementService
        self.xpService = xpService
        self.appState = appState
    }

    private let achievementService: AchievementService
    private let xpService: XPService
    private let appState: AppState

    private(set) var earned: [ProfileAchievementCache] = []

    private(set) var allAchievements: [AchievementCache] = []

    private(set) var avatarCard: AvatarCardModel?

    private(set) var lastError: String?

    private var achievementByCanonicalKey: [String: AchievementCache] = [:]

    var earnedAchievementRecordNames: Set<String> {
        Set(earned.map(\.achievementRecordName))
    }

    /// Determines if an achievement has been earned, matching by full recordName,
    /// requirement type raw value, or requirement suffix.
    func isAchievementEarned(_ achievement: AchievementCache) -> Bool {
        let earnedNames = earnedAchievementRecordNames
        if earnedNames.contains(achievement.recordName) {
            return true
        }
        if let req = achievement.requirementTypeEnum?.rawValue {
            if earnedNames.contains(req) {
                return true
            }
            if earnedNames.contains(where: { $0.hasSuffix("-\(req)") || $0 == req }) {
                return true
            }
        }
        if earnedNames.contains(where: { earnedName in
            achievement.recordName.hasSuffix("-\(earnedName)") || earnedName.hasSuffix("-\(achievement.recordName)")
        }) {
            return true
        }
        return false
    }

    var latestEarnedTrophyName: String? {
        guard let latest = earned.max(by: { $0.earnedDate < $1.earnedDate }) else { return nil }
        return achievementByCanonicalKey[latest.achievementRecordName]?.name
    }

    func rebuildLists(earned: [ProfileAchievementCache], allAchievements: [AchievementCache]) {
        guard let profile = appState.currentProfile else { return }
        let profileName = profile.id.recordName

        self.earned = earned.filter { $0.profileRecordName == profileName }

        var achievementsToUse = allAchievements
        if achievementsToUse.isEmpty, let family = appState.family {
            achievementsToUse = achievementService.cachedOrSeededAchievementCaches(for: family)
        }

        let filteredAchievements: [AchievementCache] = if FeatureFlags.rpgImmersive {
            achievementsToUse
        } else {
            achievementsToUse.filter { cache in
                guard let req = cache.requirementTypeEnum else { return false }
                switch req {
                case .firstQuest, .questCount10, .questCount25, .questCount50, .questCount100, .weekly100, .streak7, .streak30, .firstGoalCreated, .goalGetter, .ledgerCount10,
                     .earlyBird9am:
                    return true
                case .gold100, .gold500, .ledgerWeeks4:
                    return false
                }
            }
        }
        self.allAchievements = filteredAchievements.sorted(by: { $0.name < $1.name })
        // Index by both requirement type and recordName for fast lookup.
        var lookup: [String: AchievementCache] = [:]
        for achievement in self.allAchievements {
            let canonicalKey = achievement.requirementTypeEnum?.rawValue ?? achievement.recordName
            lookup[canonicalKey] = achievement
            if canonicalKey != achievement.recordName {
                lookup[achievement.recordName] = achievement
            }
        }
        self.achievementByCanonicalKey = lookup
        // Legacy RPG chrome hidden when FeatureFlags.rpgImmersive is false.
        if FeatureFlags.rpgImmersive {
            avatarCard = makeAvatarCard(profile: profile)
        } else {
            avatarCard = nil
        }
    }

    private func makeAvatarCard(profile: Profile) -> AvatarCardModel {
        let progress = xpService.levelProgress(profile: profile)
        return AvatarCardModel(
            displayName: profile.displayName,
            avatarClass: profile.avatarClass,
            customAvatarImageData: profile.customAvatarImageData,
            role: profile.role,
            title: XPService.title(forLevel: profile.level),
            level: profile.level,
            xpIntoCurrentLevel: progress.xpIntoCurrentLevel,
            xpForNextLevel: progress.xpForNextLevel,
            progress: progress.progress,
            accessories: xpService.unlockedAccessories(profile: profile)
        )
    }
}

struct AvatarCardModel: Equatable, Sendable {
    let displayName: String
    let avatarClass: AvatarClass?
    let customAvatarImageData: Data?
    let role: UserRole
    let title: String
    let level: Int
    let xpIntoCurrentLevel: Int
    let xpForNextLevel: Int
    let progress: Double
    let accessories: [String]

    var effectiveClassDisplay: String {
        if let avatarClass {
            avatarClass.displayName
        } else {
            role.genericRoleName
        }
    }
}
