//
//  AchievementService.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import os

/// V1 Trophy Spec (12) — canonical source for AchievementRequirement. Must stay in sync with ARCHITECTURE.md §1 (quest-count tiers + First Goal Created + Goal Getter);
/// TrophyRoomViewModel builds its canonical lookup via `requirementTypeEnum?.rawValue ?? recordName`.
enum AchievementRequirement: String, CaseIterable, Codable, Sendable {
    case firstQuest
    case questCount10
    case questCount25
    case questCount50
    case questCount100
    case weekly100
    case streak7
    case streak30
    case firstGoalCreated
    case goalGetter
    case ledgerCount10
    case earlyBird9am
    // Legacy — retained for decode of pre-pivot CloudKit records; not seeded in V1.
    case gold100
    case gold500
    case ledgerWeeks4
}

enum AchievementCategory: String, Codable, Sendable {
    case quest
    case streak
    case gold
    case special
    case goal
}

enum AchievementServiceError: Error, LocalizedError, Equatable, Sendable {
    case persistenceFailed

    var errorDescription: String? {
        "Could not save achievement. Please try again."
    }
}

struct ProfileStats: Sendable {
    let questCount: Int
    let bestWeeklyCompletion: Double
    let longestStreakDays: Int
    let totalGoldEarned: Double
    let ledgerCount: Int
    let ledgerWeeksCount: Int
    let earlyBirdQualified: Bool
    let goalsCreated: Int
    let goalsCompleted: Int

    init(
        questCount: Int,
        bestWeeklyCompletion: Double,
        longestStreakDays: Int,
        totalGoldEarned: Double = 0,
        ledgerCount: Int,
        ledgerWeeksCount: Int = 0,
        earlyBirdQualified: Bool,
        goalsCreated: Int = 0,
        goalsCompleted: Int = 0
    ) {
        self.questCount = questCount
        self.bestWeeklyCompletion = bestWeeklyCompletion
        self.longestStreakDays = longestStreakDays
        self.totalGoldEarned = totalGoldEarned
        self.ledgerCount = ledgerCount
        self.ledgerWeeksCount = ledgerWeeksCount
        self.earlyBirdQualified = earlyBirdQualified
        self.goalsCreated = goalsCreated
        self.goalsCompleted = goalsCompleted
    }
}

@MainActor
@Observable
final class AchievementService {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "AchievementService")

    let cacheService: CacheService?
    var syncCoordinator: CKSyncEngineCoordinator?

    let toastManager: ToastManager?

    var appState: AppState?

    var notificationService: NotificationService?

    /// Celebration surface for newly awarded trophies and streak milestones.
    var celebrationManager: CelebrationManager?

    init(
        cloudKit: any CloudKitServiceProtocol,
        cacheService: CacheService? = nil,
        toastManager: ToastManager? = nil,
        appState: AppState? = nil,
        celebrationManager: CelebrationManager? = nil,
        syncCoordinator: CKSyncEngineCoordinator? = nil
    ) {
        self.cloudKit = cloudKit
        self.cacheService = cacheService
        self.toastManager = toastManager
        self.appState = appState
        self.celebrationManager = celebrationManager
        self.syncCoordinator = syncCoordinator
    }

    private let cloudKit: any CloudKitServiceProtocol

    func seedDefaultAchievements(family: Family) async throws {
        guard let appState, let acting = appState.currentProfile, acting.role.isParent else {
            return
        }

        let familyName = family.id.recordName
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let defaults = Self.defaultAchievements(for: familyRef)

        if let cache = cacheService {
            let cached = cache.fetchAchievements(family: familyName)
            let cachedIDs = Set(cached.map(\.recordName))
            let scope: CKDatabase.Scope = appState.activeDatabaseScope
            if cache.isCacheAuthoritative(familyRecordName: familyName, type: .achievement, scope: scope, cachedCount: cached.count),
               defaults.allSatisfy({ cachedIDs.contains($0.id.recordName) })
            {
                return
            }
        }

        let existing = try await fetchAllDefinitions(family: family)
        let existingIDs = Set(existing.map(\.id.recordName))

        let toSeed = defaults.filter { !existingIDs.contains($0.id.recordName) }

        for achievement in toSeed {
            await cacheService?.upsertAchievement(achievement)
            ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(
                syncCoordinator,
                id: achievement.id,
                appState: appState,
                logger: logger,
                context: "AchievementService.seedDefaultAchievements"
            )
        }
    }

    static func defaultAchievements(for familyRef: CKRecord.Reference) -> [Achievement] {
        questAchievements(for: familyRef)
            + streakAchievements(for: familyRef)
            + goalAchievements(for: familyRef)
            + specialAchievements(for: familyRef)
    }

    static func questAchievements(for familyRef: CKRecord.Reference) -> [Achievement] {
        let zoneID = familyRef.recordID.zoneID
        return [
            Achievement(
                id: CKRecord.ID(recordName: "\(familyRef.recordID.recordName)-\(AchievementRequirement.firstQuest.rawValue)", zoneID: zoneID),
                name: "First Steps",
                description: "Complete your first quest",
                iconSystemName: "shoeprints.fill",
                category: AchievementCategory.quest,
                requirementType: AchievementRequirement.firstQuest,
                requirementValue: 1,
                family: familyRef
            ),
            Achievement(
                id: CKRecord.ID(recordName: "\(familyRef.recordID.recordName)-\(AchievementRequirement.questCount10.rawValue)", zoneID: zoneID),
                name: "Questing Squire",
                description: "Complete 10 quests",
                iconSystemName: "flag.checkered",
                category: AchievementCategory.quest,
                requirementType: AchievementRequirement.questCount10,
                requirementValue: 10,
                family: familyRef
            ),
            Achievement(
                id: CKRecord.ID(recordName: "\(familyRef.recordID.recordName)-\(AchievementRequirement.questCount25.rawValue)", zoneID: zoneID),
                name: "Questing Apprentice",
                description: "Complete 25 quests",
                iconSystemName: "flag.2.crossed.fill",
                category: AchievementCategory.quest,
                requirementType: AchievementRequirement.questCount25,
                requirementValue: 25,
                family: familyRef
            ),
            Achievement(
                id: CKRecord.ID(recordName: "\(familyRef.recordID.recordName)-\(AchievementRequirement.questCount50.rawValue)", zoneID: zoneID),
                name: "Quest Knight",
                description: "Complete 50 quests",
                iconSystemName: "figure.fencing",
                category: AchievementCategory.quest,
                requirementType: AchievementRequirement.questCount50,
                requirementValue: 50,
                family: familyRef
            ),
            Achievement(
                id: CKRecord.ID(recordName: "\(familyRef.recordID.recordName)-\(AchievementRequirement.questCount100.rawValue)", zoneID: zoneID),
                name: "Quest Legend",
                description: "Complete 100 quests",
                iconSystemName: "trophy.fill",
                category: AchievementCategory.quest,
                requirementType: AchievementRequirement.questCount100,
                requirementValue: 100,
                family: familyRef
            )
        ]
    }

    static func streakAchievements(for familyRef: CKRecord.Reference) -> [Achievement] {
        let zoneID = familyRef.recordID.zoneID
        return [
            Achievement(
                id: CKRecord.ID(recordName: "\(familyRef.recordID.recordName)-\(AchievementRequirement.streak7.rawValue)", zoneID: zoneID),
                name: "Iron Will",
                description: "7-day streak",
                iconSystemName: "flame.fill",
                category: AchievementCategory.streak,
                requirementType: AchievementRequirement.streak7,
                requirementValue: 7,
                family: familyRef
            ),
            Achievement(
                id: CKRecord.ID(recordName: "\(familyRef.recordID.recordName)-\(AchievementRequirement.streak30.rawValue)", zoneID: zoneID),
                name: "Unstoppable",
                description: "30-day streak",
                iconSystemName: "bolt.fill",
                category: AchievementCategory.streak,
                requirementType: AchievementRequirement.streak30,
                requirementValue: 30,
                family: familyRef
            )
        ]
    }

    static func goalAchievements(for familyRef: CKRecord.Reference) -> [Achievement] {
        let zoneID = familyRef.recordID.zoneID
        return [
            Achievement(
                id: CKRecord.ID(recordName: "\(familyRef.recordID.recordName)-\(AchievementRequirement.firstGoalCreated.rawValue)", zoneID: zoneID),
                name: "First Goal Created",
                description: "Create your first savings goal",
                iconSystemName: "target",
                category: AchievementCategory.goal,
                requirementType: AchievementRequirement.firstGoalCreated,
                requirementValue: 1,
                family: familyRef
            ),
            Achievement(
                id: CKRecord.ID(recordName: "\(familyRef.recordID.recordName)-\(AchievementRequirement.goalGetter.rawValue)", zoneID: zoneID),
                name: "Goal Getter",
                description: "Reach a savings goal",
                iconSystemName: "star.circle.fill",
                category: AchievementCategory.goal,
                requirementType: AchievementRequirement.goalGetter,
                requirementValue: 1,
                family: familyRef
            )
        ]
    }

    static func specialAchievements(for familyRef: CKRecord.Reference) -> [Achievement] {
        let zoneID = familyRef.recordID.zoneID
        return [
            Achievement(
                id: CKRecord.ID(recordName: "\(familyRef.recordID.recordName)-\(AchievementRequirement.weekly100.rawValue)", zoneID: zoneID),
                name: "Week Warrior",
                description: "Complete all quests in a week",
                iconSystemName: "calendar.badge.checkmark",
                category: AchievementCategory.special,
                requirementType: AchievementRequirement.weekly100,
                requirementValue: 1,
                family: familyRef
            ),
            Achievement(
                id: CKRecord.ID(recordName: "\(familyRef.recordID.recordName)-\(AchievementRequirement.ledgerCount10.rawValue)", zoneID: zoneID),
                name: "Chronicler",
                description: "Log 10 spending entries",
                iconSystemName: "scroll.fill",
                category: AchievementCategory.special,
                requirementType: AchievementRequirement.ledgerCount10,
                requirementValue: 10,
                family: familyRef
            ),
            Achievement(
                id: CKRecord.ID(recordName: "\(familyRef.recordID.recordName)-\(AchievementRequirement.earlyBird9am.rawValue)", zoneID: zoneID),
                name: "Early Bird",
                description: "Complete a quest before 9 AM",
                iconSystemName: "sun.max.fill",
                category: AchievementCategory.special,
                requirementType: AchievementRequirement.earlyBird9am,
                requirementValue: 1,
                family: familyRef
            )
        ]
    }

    func cachedOrSeededAchievementCaches(for family: Family) -> [AchievementCache] {
        let familyName = family.id.recordName
        if let cache = cacheService {
            let existing = cache.fetchAchievements(family: familyName)
            if !existing.isEmpty {
                return existing
            }
        }
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        return Self.defaultAchievements(for: familyRef).map { AchievementCache(from: $0) }
    }

    func ensureDefaultAchievements(for family: Family) async -> [AchievementCache] {
        let familyName = family.id.recordName
        if let cache = cacheService {
            let existing = cache.fetchAchievements(family: familyName)
            if !existing.isEmpty {
                return existing
            }
        }
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let defaults = Self.defaultAchievements(for: familyRef)
        if let handler = syncCoordinator?.delegateHandler {
            let scope: CKDatabase.Scope = appState?.activeDatabaseScope ?? DatabaseScopeResolver.scope(isOwner: false)
            await handler.hydrateFromQuery(models: defaults, databaseScope: scope, zoneID: family.id.zoneID)
            if appState?.currentProfile?.role.isParent == true {
                ActiveFamilyScopeGuard.batchEnqueueWithCorrectedOwner(
                    syncCoordinator,
                    ids: defaults.map(\.id),
                    appState: appState,
                    logger: logger,
                    context: "AchievementService.ensureDefaultAchievements"
                )
            }
        } else if let cache = cacheService {
            for achievement in defaults {
                await cache.upsertAchievement(achievement)
                if appState?.currentProfile?.role.isParent == true {
                    ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(
                        syncCoordinator,
                        id: achievement.id,
                        appState: appState,
                        logger: logger,
                        context: "AchievementService.ensureDefaultAchievements"
                    )
                }
            }
        }
        return defaults.map { AchievementCache(from: $0) }
    }

    func fetchAllDefinitions(family: Family) async throws -> [Achievement] {
        let familyName = family.id.recordName
        if let cache = cacheService {
            let cached = cache.fetchAchievements(family: familyName)
            let scope: CKDatabase.Scope = appState?.activeDatabaseScope ?? DatabaseScopeResolver.scope(isOwner: false)
            if cache.isCacheAuthoritative(familyRecordName: familyName, type: .achievement, scope: scope, cachedCount: cached.count) {
                return cached.map { $0.toAchievement(zoneID: family.id.zoneID) }
            }
        }
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let predicate = NSPredicate(format: "family == %@", familyRef)
        do {
            let results = try await cloudKit.query(Achievement.self, predicate: predicate, in: family.id.zoneID)
            if !results.isEmpty {
                await syncCoordinator?.delegateHandler.hydrateFromQuery(
                    models: results,
                    databaseScope: appState?.activeDatabaseScope ?? DatabaseScopeResolver.scope(isOwner: false),
                    zoneID: family.id.zoneID
                )
                return results
            }
        } catch {
            logger.debug("Querying achievement definitions from CloudKit skipped/failed: \(error, privacy: .private)")
        }
        // Fallback to default achievement definitions if none were in CloudKit/cache yet.
        let defaults = Self.defaultAchievements(for: familyRef)
        for achievement in defaults {
            await cacheService?.upsertAchievement(achievement)
            if appState?.currentProfile?.role.isParent == true {
                ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(
                    syncCoordinator,
                    id: achievement.id,
                    appState: appState,
                    logger: logger,
                    context: "AchievementService.fetchAllDefinitions.fallback"
                )
            }
        }
        return defaults
    }

    func fetchEarned(profile: Profile) async throws -> [ProfileAchievement] {
        try await fetchEarned(profile: profile, family: nil)
    }

    func fetchEarned(profile: Profile, family: Family?) async throws -> [ProfileAchievement] {
        let profileName = profile.id.recordName
        let primaryFamilyName = family?.id.recordName ?? profile.family.recordID.recordName
        let fallbackFamilyName = profile.family.recordID.recordName

        if let cache = cacheService {
            var cached = cache.fetchProfileAchievements(profileRecordName: profileName, family: primaryFamilyName)
            if cached.isEmpty, fallbackFamilyName != primaryFamilyName {
                cached = cache.fetchProfileAchievements(profileRecordName: profileName, family: fallbackFamilyName)
            }
            if !cached.isEmpty {
                return cached.map { $0.toProfileAchievement(zoneID: profile.id.zoneID) }
                    .sorted { $0.earnedDate > $1.earnedDate }
            }
        }

        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(format: "profile == %@", profileRef)
        do {
            let results = try await cloudKit.query(
                ProfileAchievement.self,
                predicate: predicate,
                in: profile.id.zoneID,
                sortDescriptors: [NSSortDescriptor(key: "earnedDate", ascending: false)]
            )
            await syncCoordinator?.delegateHandler.hydrateFromQuery(
                models: results,
                databaseScope: appState?.activeDatabaseScope ?? DatabaseScopeResolver.scope(isOwner: false),
                zoneID: profile.id.zoneID
            )
            return results
        } catch {
            logger.debug("Querying earned achievements from CloudKit skipped/failed: \(error, privacy: .private)")
            if let cache = cacheService {
                var cached = cache.fetchProfileAchievements(profileRecordName: profileName, family: primaryFamilyName)
                if cached.isEmpty, fallbackFamilyName != primaryFamilyName {
                    cached = cache.fetchProfileAchievements(profileRecordName: profileName, family: fallbackFamilyName)
                }
                return cached.map { $0.toProfileAchievement(zoneID: profile.id.zoneID) }
                    .sorted { $0.earnedDate > $1.earnedDate }
            }
            return []
        }
    }

    private func filterUnearnedDefinitions(
        allDefinitions: [Achievement],
        existingEarned: [ProfileAchievement]
    ) -> [Achievement] {
        let earnedAchievementIDs = Set(existingEarned.map(\.achievement.recordID.recordName))
        let earnedRequirementTypes = Set(existingEarned.compactMap { pa -> String? in
            let rec = pa.achievement.recordID.recordName
            for req in AchievementRequirement.allCases {
                if rec == req.rawValue || rec.hasSuffix("-\(req.rawValue)") {
                    return req.rawValue
                }
            }
            return nil
        })

        return allDefinitions.filter { def in
            if earnedAchievementIDs.contains(def.id.recordName) {
                return false
            }
            if earnedRequirementTypes.contains(def.requirementType.rawValue) {
                return false
            }
            return true
        }
    }

    private func sendAwardNotifications(for awarded: [Achievement], to profile: Profile) async {
        guard let notificationService, !awarded.isEmpty else { return }

        for achievement in awarded {
            do {
                try await notificationService.send(
                    .trophyEarned,
                    to: profile,
                    title: "🏅 Trophy Earned!",
                    body: "You unlocked '\(achievement.name)'!"
                )
            } catch {
                let achievementName = achievement.id.recordName
                let profileName = profile.id.recordName
                logger.error(
                    "Failed to send trophyEarned notification for \(achievementName, privacy: .private) to profile \(profileName, privacy: .private): \(error, privacy: .private)"
                )
            }
        }

        let newlyAwardedStreakThresholds = awarded.compactMap { achievement -> Int? in
            switch achievement.requirementType {
            case .streak7: return 7
            case .streak30: return 30
            default: return nil
            }
        }
        for streakDays in newlyAwardedStreakThresholds.sorted() {
            do {
                try await notificationService.send(
                    .streakMilestone,
                    to: profile,
                    title: "🔥 Streak Milestone!",
                    body: "You've hit a \(streakDays)-day streak!"
                )
            } catch {
                let profileName = profile.id.recordName
                logger.error(
                    "Failed to send streakMilestone notification for \(streakDays)-day streak to profile \(profileName, privacy: .private): \(error, privacy: .private)"
                )
            }
        }
    }

    @discardableResult
    func evaluateAll(for profile: Profile, family: Family) async throws -> [Achievement] {
        guard let acting = appState?.currentProfile, acting.id == profile.id || acting.role.isParent else {
            return []
        }

        let existingEarned = try await fetchEarned(profile: profile, family: family)
        let allDefinitions = try await fetchAllDefinitions(family: family)
        let unearned = filterUnearnedDefinitions(allDefinitions: allDefinitions, existingEarned: existingEarned)

        let stats = try await computeStats(for: profile, family: family)
        let statSummary = "quests=\(stats.questCount), goals=\(stats.goalsCreated), completed=\(stats.goalsCompleted), unearned=\(unearned.count)"
        logger.info("Evaluating trophies for \(profile.displayName, privacy: .public): \(statSummary, privacy: .public)")

        var awarded: [Achievement] = []
        for definition in unearned where isRequirementMet(definition: definition, stats: stats) {
            _ = try await award(definition, to: profile, family: family)
            awarded.append(definition)
        }

        await sendAwardNotifications(for: awarded, to: profile)

        // Forward newly awarded achievements to the celebration surface ONLY if the
        // current active device is the hero who earned the achievement. Parents approving
        // quests remotely must not see child trophy unlock toasts/confetti on their device.
        let isParentActingOnChild = (appState?.currentProfile?.role.isParent == true && appState?.currentProfile?.id != profile.id)
        if !isParentActingOnChild {
            celebrationManager?.enqueue(achievements: awarded, for: profile)

            // Centralized haptic + overlay feedback for unlocks
            if !awarded.isEmpty {
                triggerUnlockFeedback(for: awarded)
            }
        }

        return awarded
    }

    /// Quest-completion hook — re-evaluates trophies after a verified completion.
    @discardableResult
    func handleQuestCompleted(for profile: Profile, family: Family) async throws -> [Achievement] {
        try await evaluateAll(for: profile, family: family)
    }

    /// Goal creation hook — award First Goal Created and re-check Goal Getter.
    @discardableResult
    func handleGoalCreated(for profile: Profile, family: Family) async throws -> [Achievement] {
        try await evaluateAll(for: profile, family: family)
    }

    /// Goal completion hook — award Goal Getter when a savings goal is reached.
    @discardableResult
    func handleGoalCompleted(for profile: Profile, family: Family) async throws -> [Achievement] {
        try await evaluateAll(for: profile, family: family)
    }

    private func triggerUnlockFeedback(for _: [Achievement]) {
        HapticsService.success()
        celebrationManager?.triggerConfetti()
    }

    func award(_ achievement: Achievement,
               to profile: Profile,
               family: Family) async throws -> ProfileAchievement
    {
        guard let acting = appState?.currentProfile, acting.id == profile.id || acting.role.isParent else {
            throw FamilyServiceError.unauthorized
        }

        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let row = ProfileAchievement(
            achievement: CKRecord.Reference(recordID: achievement.id, action: .none),
            profile: CKRecord.Reference(recordID: profile.id, action: .none),
            family: familyRef,
            id: ProfileAchievement.recordID(
                profileID: profile.id,
                achievementID: achievement.id,
                zoneID: profile.id.zoneID
            )
        )

        await cacheService?.upsertProfileAchievement(row)
        ActiveFamilyScopeGuard.enqueueWithCorrectedOwner(
            syncCoordinator,
            id: row.id,
            appState: appState,
            logger: logger,
            context: "AchievementService.award"
        )
        if let syncCoordinator {
            Task {
                await syncCoordinator.sendPendingChanges()
            }
        }
        logger
            .info(
                "Successfully awarded trophy '\(achievement.name, privacy: .public)' (id: \(achievement.id.recordName, privacy: .public)) to profile \(profile.displayName, privacy: .public)"
            )
        return row
    }
}

// MARK: - AchievementService Helpers

@MainActor
private extension AchievementService {
    func fetchCompletedLogs(for profile: Profile, family: Family) async throws -> [QuestCompletion] {
        let profileName = profile.id.recordName
        let zoneID = profile.id.zoneID
        let primaryFamilyName = family.id.recordName
        let fallbackFamilyName = profile.family.recordID.recordName
        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)

        if let cache = cacheService {
            let scope: CKDatabase.Scope = appState?.activeDatabaseScope ?? DatabaseScopeResolver.scope(isOwner: false)
            let cachedLogs = cache.fetchQuestCompletions(family: primaryFamilyName)
                .filter { $0.completerRecordName == profileName }
            if cache.isCacheAuthoritative(familyRecordName: primaryFamilyName, type: .questCompletion, scope: scope, cachedCount: cachedLogs.count) {
                return cachedLogs
                    .map { $0.toQuestCompletion(zoneID: zoneID) }
                    .filter { $0.verificationStatus == .verified || $0.verificationStatus == .autoApproved }
            }
        }

        do {
            let questLogs = try await cloudKit.query(
                QuestCompletion.self,
                predicate: NSPredicate(format: "completedBy == %@", profileRef),
                in: zoneID
            )
            await syncCoordinator?.delegateHandler.hydrateFromQuery(
                models: questLogs,
                databaseScope: appState?.activeDatabaseScope ?? DatabaseScopeResolver.scope(isOwner: false),
                zoneID: zoneID
            )
            return questLogs.filter {
                $0.verificationStatus == .verified || $0.verificationStatus == .autoApproved
            }
        } catch {
            logger.debug("Querying completed logs from CloudKit skipped/failed: \(error, privacy: .private)")
            if let cache = cacheService {
                var cachedLogs = cache.fetchQuestCompletions(family: primaryFamilyName)
                    .filter { $0.completerRecordName == profileName }
                if cachedLogs.isEmpty, fallbackFamilyName != primaryFamilyName {
                    cachedLogs = cache.fetchQuestCompletions(family: fallbackFamilyName)
                        .filter { $0.completerRecordName == profileName }
                }
                return cachedLogs
                    .map { $0.toQuestCompletion(zoneID: zoneID) }
                    .filter { $0.verificationStatus == .verified || $0.verificationStatus == .autoApproved }
            }
            return []
        }
    }

    func fetchLedgerEntries(for profile: Profile, family: Family) async throws -> [LedgerEntry] {
        let profileName = profile.id.recordName
        let zoneID = profile.id.zoneID
        let primaryFamilyName = family.id.recordName
        let fallbackFamilyName = profile.family.recordID.recordName
        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)

        if let cache = cacheService {
            let scope: CKDatabase.Scope = appState?.activeDatabaseScope ?? DatabaseScopeResolver.scope(isOwner: false)
            let cachedLedger = cache.fetchLedgerEntries(
                profileRecordName: profileName,
                family: primaryFamilyName
            )
            if cache.isCacheAuthoritative(familyRecordName: primaryFamilyName, type: .ledgerEntry, scope: scope, cachedCount: cachedLedger.count) {
                return cachedLedger.map { $0.toLedgerEntry(zoneID: zoneID) }
            }
        }

        do {
            let ledger = try await cloudKit.query(
                LedgerEntry.self,
                predicate: NSPredicate(format: "profile == %@", profileRef),
                in: zoneID
            )
            await syncCoordinator?.delegateHandler.hydrateFromQuery(
                models: ledger,
                databaseScope: appState?.activeDatabaseScope ?? DatabaseScopeResolver.scope(isOwner: false),
                zoneID: zoneID
            )
            return ledger
        } catch {
            logger.debug("Querying ledger entries from CloudKit skipped/failed: \(error, privacy: .private)")
            if let cache = cacheService {
                var cachedLedger = cache.fetchLedgerEntries(
                    profileRecordName: profileName,
                    family: primaryFamilyName
                )
                if cachedLedger.isEmpty, fallbackFamilyName != primaryFamilyName {
                    cachedLedger = cache.fetchLedgerEntries(
                        profileRecordName: profileName,
                        family: fallbackFamilyName
                    )
                }
                return cachedLedger.map { $0.toLedgerEntry(zoneID: zoneID) }
            }
            return []
        }
    }

    func fetchGoals(for profile: Profile, family: Family) async throws -> [Goal] {
        let profileName = profile.id.recordName
        let zoneID = profile.id.zoneID
        let primaryFamilyName = family.id.recordName
        let fallbackFamilyName = profile.family.recordID.recordName

        if let cache = cacheService {
            let scope: CKDatabase.Scope = appState?.activeDatabaseScope ?? DatabaseScopeResolver.scope(isOwner: false)
            let cached = cache.fetchGoals(family: primaryFamilyName)
                .filter { $0.profileRecordName == profileName }
            if cache.isCacheAuthoritative(familyRecordName: primaryFamilyName, type: .goal, scope: scope, cachedCount: cached.count) {
                return cached.map { $0.toGoal(zoneID: zoneID) }
            }
        }

        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(format: "profile == %@", profileRef)
        do {
            let results = try await cloudKit.query(Goal.self, predicate: predicate, in: zoneID)
            await syncCoordinator?.delegateHandler.hydrateFromQuery(
                models: results,
                databaseScope: appState?.activeDatabaseScope ?? DatabaseScopeResolver.scope(isOwner: false),
                zoneID: zoneID
            )
            return results
        } catch {
            logger.debug("Querying goals from CloudKit skipped/failed: \(error, privacy: .private)")
            if let cache = cacheService {
                var cached = cache.fetchGoals(family: primaryFamilyName)
                    .filter { $0.profileRecordName == profileName }
                if cached.isEmpty, fallbackFamilyName != primaryFamilyName {
                    cached = cache.fetchGoals(family: fallbackFamilyName)
                        .filter { $0.profileRecordName == profileName }
                }
                return cached.map { $0.toGoal(zoneID: zoneID) }
            }
            return []
        }
    }

    func fetchQuestCache(
        for completedLogs: [QuestCompletion],
        profileID: CKRecord.ID,
        familyName: String,
        zoneID: CKRecordZone.ID
    ) async throws -> [CKRecord.ID: Quest] {
        var questCache: [CKRecord.ID: Quest] = [:]

        if let cache = cacheService {
            let cachedQuests = cache.fetchQuests(family: familyName)
            let scope: CKDatabase.Scope = appState?.activeDatabaseScope ?? DatabaseScopeResolver.scope(isOwner: false)
            if cache.isCacheAuthoritative(familyRecordName: familyName, type: .quest, scope: scope, cachedCount: cachedQuests.count) {
                for questCacheRow in cachedQuests {
                    let questObj = questCacheRow.toQuest(zoneID: zoneID)
                    questCache[questObj.id] = questObj
                }
                return questCache
            }
        }

        let profileRef = CKRecord.Reference(recordID: profileID, action: .none)
        let predicate = NSPredicate(format: "assignee == %@", profileRef)
        do {
            let assignedQuests = try await cloudKit.query(
                Quest.self,
                predicate: predicate,
                in: zoneID,
                sortDescriptors: nil
            )
            for quest in assignedQuests {
                questCache[quest.id] = quest
            }
            await syncCoordinator?.delegateHandler.hydrateFromQuery(
                models: assignedQuests,
                databaseScope: appState?.activeDatabaseScope ?? DatabaseScopeResolver.scope(isOwner: false),
                zoneID: zoneID
            )
        } catch {
            logger.debug("Failed to query assigned quests for profile \(profileID.recordName, privacy: .private): \(error, privacy: .private)")
        }

        let missingQuestIDs = Set(completedLogs.map(\.quest.recordID)).subtracting(questCache.keys)
        var fetchedMissing: [Quest] = []
        for questID in missingQuestIDs {
            do {
                let fetched = try await cloudKit.fetch(Quest.self, id: questID)
                questCache[questID] = fetched
                fetchedMissing.append(fetched)
            } catch {
                logger.debug("Failed to fetch quest \(questID.recordName, privacy: .private): \(error, privacy: .private)")
            }
        }
        if !fetchedMissing.isEmpty {
            await syncCoordinator?.delegateHandler.hydrateFromQuery(
                models: fetchedMissing,
                databaseScope: appState?.activeDatabaseScope ?? DatabaseScopeResolver.scope(isOwner: false),
                zoneID: zoneID
            )
        }
        return questCache
    }

    func computeStats(for profile: Profile, family: Family) async throws -> ProfileStats {
        let completedLogs = try await fetchCompletedLogs(for: profile, family: family)
        let ledger = try await fetchLedgerEntries(for: profile, family: family)
        let goals = try await fetchGoals(for: profile, family: family)
        let questCache = try await fetchQuestCache(
            for: completedLogs,
            profileID: profile.id,
            familyName: family.id.recordName,
            zoneID: profile.id.zoneID
        )

        var totalGold: Double = 0
        var dailyCompletionDates: Set<Int> = []
        var weekCompletionCounts: [Date: Int] = [:]
        var earlyBird = false
        var approvedCountByQuest: [CKRecord.ID: Int] = [:]

        for log in completedLogs {
            guard let quest = questCache[log.quest.recordID] else { continue }
            approvedCountByQuest[quest.id, default: 0] += 1

            dailyCompletionDates.insert(WeekMath.dayBucket(for: log.completedDate))
            weekCompletionCounts[quest.weekOf, default: 0] += 1

            let hour = Calendar.iso8601UTC.component(.hour, from: log.completedDate)
            if hour < AppConstants.Economy.earlyBirdHourCutoff {
                earlyBird = true
            }
        }

        for (questID, approvedCount) in approvedCountByQuest {
            if let quest = questCache[questID] {
                totalGold += GoldCalculation.creditAsDouble(for: quest, approvedCount: approvedCount)
            }
        }

        let streakDays = longestConsecutiveStreak(in: dailyCompletionDates)
        let bestWeekly = computeBestWeeklyCompletion(
            profile: profile,
            approvedCountByQuest: approvedCountByQuest,
            questCache: questCache
        )

        // Ledger weeks ride the hero's payout-day-aware cycles via WeekMath so
        // the legacy week-count stat agrees with the app's week cycles.
        let payoutDay = profile.payoutDay ?? family.payoutDay
        var ledgerWeekRoots = Set<Date>()
        for entry in ledger {
            ledgerWeekRoots.insert(WeekMath.startOfWeek(for: entry.date, payoutDay: payoutDay))
        }

        let goalsCreated = goals.count
        let goalsCompleted = goals.filter { $0.completedAt != nil }.count

        return ProfileStats(
            questCount: completedLogs.count,
            bestWeeklyCompletion: bestWeekly,
            longestStreakDays: streakDays,
            totalGoldEarned: totalGold,
            ledgerCount: ledger.count,
            ledgerWeeksCount: ledgerWeekRoots.count,
            earlyBirdQualified: earlyBird,
            goalsCreated: goalsCreated,
            goalsCompleted: goalsCompleted
        )
    }

    func computeBestWeeklyCompletion(
        profile: Profile,
        approvedCountByQuest: [CKRecord.ID: Int],
        questCache: [CKRecord.ID: Quest]
    ) -> Double {
        var bestWeekly = 0.0
        let assignedQuests = questCache.values.filter {
            $0.assignee.recordID == profile.id && $0.active
        }
        let questsByWeek = Dictionary(grouping: assignedQuests, by: \.weekOf)
        for (_, weekQuests) in questsByWeek {
            guard !weekQuests.isEmpty else { continue }
            let fullyCompletedCount = weekQuests.filter { quest in
                let approvedCount = approvedCountByQuest[quest.id] ?? 0
                return GoldCalculation.isFullyCompleted(quest: quest, approvedCount: approvedCount)
            }.count
            let ratio = Double(fullyCompletedCount) / Double(weekQuests.count)
            bestWeekly = max(bestWeekly, min(ratio, 1.0))
        }
        return bestWeekly
    }

    func longestConsecutiveStreak(in days: Set<Int>) -> Int {
        guard !days.isEmpty else { return 0 }

        let sorted = days.sorted()
        var best = 1
        var run = 1
        for index in 1 ..< sorted.count {
            // Buckets are epoch-day integers, so a gap of exactly 1 is consecutive days.
            if sorted[index] - sorted[index - 1] == 1 {
                run += 1
                if run > best {
                    best = run
                }
            } else {
                run = 1
            }
        }
        return best
    }

    func isRequirementMet(definition: Achievement, stats: ProfileStats) -> Bool {
        switch definition.requirementType {
        case AchievementRequirement.firstQuest:
            stats.questCount >= 1

        case AchievementRequirement.questCount10:
            stats.questCount >= 10

        case AchievementRequirement.questCount25:
            stats.questCount >= 25

        case AchievementRequirement.questCount50:
            stats.questCount >= 50

        case AchievementRequirement.questCount100:
            stats.questCount >= 100

        case AchievementRequirement.weekly100:
            stats.bestWeeklyCompletion >= 1.0

        case AchievementRequirement.streak7:
            stats.longestStreakDays >= 7

        case AchievementRequirement.streak30:
            stats.longestStreakDays >= 30

        case AchievementRequirement.firstGoalCreated:
            stats.goalsCreated >= 1

        case AchievementRequirement.goalGetter:
            stats.goalsCompleted >= 1

        case AchievementRequirement.ledgerCount10:
            stats.ledgerCount >= 10

        case AchievementRequirement.earlyBird9am:
            stats.earlyBirdQualified

        // Legacy evaluation — keeps previously earned gold/ledger trophies decoding correctly.
        case AchievementRequirement.gold100:
            stats.totalGoldEarned >= 100

        case AchievementRequirement.gold500:
            stats.totalGoldEarned >= 500

        case AchievementRequirement.ledgerWeeks4:
            stats.ledgerWeeksCount >= 4
        }
    }
}
