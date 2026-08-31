//
//  TrophyRoomViewModel.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
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

    // WHY: single canonical lookup replaces the prior 4-way stringly-typed
    // fallback (recordName, rawValue, hasSuffix recordName, hasSuffix rawValue)
    // per ARCHITECTURE.md §1; trophy requirement text is computed at render
    // time so stored description may be stale.
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

        // WHY: keep earned scoped to the active hero and achievements sorted
        // so ForEach has stable IDs and the grid never appears empty due to
        // ordering churn; earnedAchievementRecordNames derives from this filtered set.
        self.earned = earned.filter { $0.profileRecordName == profileName }

        var achievementsToUse = allAchievements
        if achievementsToUse.isEmpty, let family = appState.family {
            let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
            let defaults = AchievementService.defaultAchievements(for: familyRef)
            achievementsToUse = defaults.map { AchievementCache(from: $0) }
        }

        // WHY: Trophy Room renders the 12 V1 achievements (legacy gold100/gold500/ledgerWeeks4 filtered out when immersive off).
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
        // WHY: build canonical lookup once so latestEarnedTrophyName is a single
        // exact-match dictionary lookup instead of a nested closure with four
        // stringly-typed fallbacks; keyed by requirementTypeEnum rawValue when
        // available (V1 spec) falling back to recordName for any untyped record.
        var lookup: [String: AchievementCache] = [:]
        for achievement in self.allAchievements {
            let canonicalKey = achievement.requirementTypeEnum?.rawValue ?? achievement.recordName
            lookup[canonicalKey] = achievement
            // Current deterministic IDs are family-prefixed (e.g., "fam1-firstQuest"); index the full recordName as well so exact match works for both legacy rawValue and current
            // prefixed shapes without hasSuffix fallbacks.
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
