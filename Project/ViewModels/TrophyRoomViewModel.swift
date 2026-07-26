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

    var earnedAchievementRecordNames: Set<String> {
        Set(earned.map(\.achievementRecordName))
    }

    func refresh() async {
        guard let profile = appState.currentProfile,
              let family = appState.family
        else {
            earned = []
            allAchievements = []
            avatarCard = nil
            return
        }

        if let cache = appState.cacheService {
            let familyName = family.id.recordName
            let profileName = profile.id.recordName
            let allDefs = cache.fetchAchievements(family: familyName)
            let earnedRows = cache.fetchProfileAchievements(profileRecordName: profileName)
            rebuildLists(earned: earnedRows, allAchievements: allDefs)
        }
    }

    func rebuildLists(earned: [ProfileAchievementCache], allAchievements: [AchievementCache]) {
        guard let profile = appState.currentProfile else { return }
        let profileName = profile.id.recordName

        self.earned = earned.filter { $0.profileRecordName == profileName }
        self.allAchievements = allAchievements
        avatarCard = makeAvatarCard(profile: profile)
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
