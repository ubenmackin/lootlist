import Foundation
import CloudKit
import Observation

@MainActor
@Observable
final class FamilyDashboardViewModel {

    private(set) var heroes: [Profile] = []

    private(set) var parents: [Profile] = []

    private(set) var weekSummary: WeekendSummary?

    private(set) var pastPayouts: [AllowancePeriod] = []

    private(set) var isLoading: Bool = false

    private(set) var isLoadingPayouts: Bool = false

    var loadError: String?

    private let questService: QuestService
    private let treasury: TreasuryService
    private let achievements: AchievementService
    private let appState: AppState

    init(questService: QuestService,
         treasury: TreasuryService,
         achievementService: AchievementService,
         appState: AppState) {
        self.questService = questService
        self.treasury = treasury
        self.achievements = achievementService
        self.appState = appState
    }

    func refresh() async {
        guard let family = appState.family else {
            heroes = []
            parents = []
            weekSummary = nil
            return
        }

        isLoading = true
        defer { isLoading = false }

        let cloudKit = questService.cloudKitReference
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let membershipPredicate = NSPredicate(format: "family == %@", familyRef)
        let members = (try? await cloudKit.query(
            Profile.self, predicate: membershipPredicate
        )) ?? []
        let active = members.filter { $0.isActive }
        self.heroes = active
            .filter { $0.role == .hero }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        self.parents = active
            .filter { $0.role.isParent }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        let weekOf = Date()
        var heroSummaries: [HeroSummary] = []
        heroSummaries.reserveCapacity(heroes.count)

        for hero in heroes {
            let summary = await buildHeroSummary(for: hero, weekOf: weekOf)
            heroSummaries.append(summary)
        }

        let totalEarned = heroSummaries.reduce(into: 0.0) { $0 += $1.weeklyGoldEarned }
        let totalQuests = heroSummaries.reduce(into: 0) { $0 += $1.weeklyQuestsCompleted }
        self.weekSummary = WeekendSummary(
            weekOf: TreasuryService.mondayOfWeek(for: weekOf),
            totalEarned: totalEarned,
            totalQuestsCompleted: totalQuests,
            heroSummaries: heroSummaries
        )

        if loadError != nil { loadError = nil }
    }

    func loadPastPayouts(includeActive: Bool = true) async {
        guard let family = appState.family else {
            pastPayouts = []
            return
        }

        isLoadingPayouts = true
        defer { isLoadingPayouts = false }

        let cloudKit = questService.cloudKitReference
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let predicate = NSPredicate(format: "family == %@", familyRef)
        let all = (try? await cloudKit.query(
            AllowancePeriod.self,
            predicate: predicate,
            sortDescriptors: [NSSortDescriptor(key: "weekOf", ascending: false)]
        )) ?? [AllowancePeriod]()
        self.pastPayouts = includeActive
            ? all
            : all.filter { $0.status == .paid }
    }

    private func buildHeroSummary(for hero: Profile,
                                    weekOf: Date) async -> HeroSummary {

        async let questsTask: [Quest]? = try? questService.fetchActiveQuests(
            profile: hero, weekOf: weekOf
        )
        async let logsTask: [QuestLog]? = try? questService.fetchQuestLogs(
            for: hero
        )
        async let streakTask: Int? = try? questService.fetchStreak(for: hero)
        async let earnedTask: Double? = try? treasury.weeklyBreakdown(
            profile: hero, weekOf: weekOf
        ).totalEarned

        async let earnedTrophiesTask: [ProfileAchievement]? = try? achievements.fetchEarned(
            profile: hero
        )

        let quests = await questsTask ?? []
        let logs = await logsTask ?? []
        let streak = await streakTask ?? 0
        let earned = await earnedTask ?? 0
        let earnedTrophies = await earnedTrophiesTask ?? []

        let monday = TreasuryService.mondayOfWeek(for: weekOf)
        let weekLogs = logs.filter { $0.weekOf == monday }
        let completed = weekLogs.filter {
            $0.verificationStatus == .autoApproved
                || $0.verificationStatus == .verified
        }

        return HeroSummary(
            profile: hero,
            weeklyQuestsCompleted: completed.count,
            weeklyQuestsTotal: quests.count,
            weeklyGoldEarned: earned,
            currentStreak: streak,
            trophiesEarned: earnedTrophies.count
        )
    }

    var isGuildMaster: Bool {
        appState.currentProfile?.role == .guildMaster
    }

    func reset() {
        heroes = []
        parents = []
        weekSummary = nil
        pastPayouts = []
        loadError = nil
        isLoading = false
        isLoadingPayouts = false
    }
}

struct WeekendSummary: Equatable, Sendable {

    let weekOf: Date

    let totalEarned: Double

    let totalQuestsCompleted: Int

    let heroSummaries: [HeroSummary]
}

extension WeekendSummary {

    var totalQuestsAssigned: Int {
        heroSummaries.reduce(into: 0) { $0 += $1.weeklyQuestsTotal }
    }
}

struct HeroSummary: Equatable, Identifiable, Sendable {

    var id: CKRecord.ID { profile.id }

    let profile: Profile

    let weeklyQuestsCompleted: Int

    let weeklyQuestsTotal: Int

    let weeklyGoldEarned: Double

    let currentStreak: Int

    let trophiesEarned: Int

    var avatarRenderSpec: AvatarRenderSpec?
}
