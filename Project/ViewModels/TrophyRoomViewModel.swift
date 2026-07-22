import Foundation
import CloudKit

@MainActor
@Observable
final class TrophyRoomViewModel {

    init(achievementService: AchievementService,
         xpService: XPService,
         appState: AppState) {
        self.achievementService = achievementService
        self.xpService = xpService
        self.appState = appState
    }

    private let achievementService: AchievementService
    private let xpService: XPService
    private let appState: AppState

    private(set) var earned: [ProfileAchievement] = []

    private(set) var allAchievements: [Achievement] = []

    private(set) var avatarCard: AvatarCardModel? = nil

    private(set) var lastError: String? = nil

    var earnedIDs: Set<CKRecord.ID> { Set(earned.map { $0.achievement.recordID }) }

    func refresh() async {
        guard let profile = appState.currentProfile,
              let family = appState.family else {
            earned = []
            allAchievements = []
            avatarCard = nil
            return
        }

        do {

            let earnedRows = try await achievementService.fetchEarned(profile: profile)
            let defs = try await achievementService.fetchAllDefinitions(family: family)
            self.earned = earnedRows
            self.allAchievements = defs
            self.avatarCard = makeAvatarCard(profile: profile)
            self.lastError = nil
        } catch {
            self.lastError = "\(error)"
        }
    }

    private func makeAvatarCard(profile: Profile) -> AvatarCardModel {
        let progress = xpService.levelProgress(profile: profile)
        return AvatarCardModel(
            displayName: profile.displayName,
            avatarClass: profile.avatarClass,
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
    let avatarClass: AvatarClass
    let title: String
    let level: Int
    let xpIntoCurrentLevel: Int
    let xpForNextLevel: Int
    let progress: Double
    let accessories: [String]
}
