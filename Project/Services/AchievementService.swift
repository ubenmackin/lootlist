//
//  AchievementService.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import os

/// WHY canonical source: AchievementRequirement stays in sync with ARCHITECTURE.md §1.
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

struct ProfileStats: Sendable {
    let questCount: Int
    let bestWeeklyCompletion: Double
    let longestStreakDays: Int
    /// Whole pennies earned across quests.
    let totalGoldEarned: Int64
    let ledgerCount: Int
    let ledgerWeeksCount: Int
    let earlyBirdQualified: Bool
    let goalsCreated: Int
    let goalsCompleted: Int

    init(
        questCount: Int,
        bestWeeklyCompletion: Double,
        longestStreakDays: Int,
        totalGoldEarned: Int64 = 0,
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
    private let logger = Logger(category: "AchievementService")

    let cacheService: (any CacheServicing)?
    var syncCoordinator: (any SyncEnqueuing)?

    var appState: AppState?

    var notificationService: NotificationService?

    /// Celebration surface for newly awarded trophies and streak milestones.
    var celebrationManager: CelebrationManager?

    init(
        cloudKit: any CloudKitServiceProtocol,
        cacheService: (any CacheServicing)? = nil,
        toastManager _: ToastManager? = nil,
        appState: AppState? = nil,
        celebrationManager: CelebrationManager? = nil,
        syncCoordinator: (any SyncEnqueuing)? = nil
    ) {
        self.cloudKit = cloudKit
        self.cacheService = cacheService
        self.appState = appState
        self.celebrationManager = celebrationManager
        self.syncCoordinator = syncCoordinator
    }

    private let cloudKit: any CloudKitServiceProtocol

    func seedDefaultAchievements(family: Family) async throws {
        guard let appState, let acting = appState.currentProfile, acting.role.isParent else {
            logger.warning("Unauthorized attempt to seed default achievements")
            return
        }

        let familyName = family.id.recordName
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let defaults = Self.defaultAchievements(for: familyRef)

        if let cache = cacheService, let scope = DatabaseScopeResolver.resolvedScope(appState: appState) {
            let cached = cache.fetchAchievements(family: familyName)
            let cachedIDs = Set(cached.map(\.recordName))
            // WHY: Bespoke seeding gate with set-membership check across defaults — intentionally inline, not a single-type CacheFirst flow.
            if cache.isCacheAuthoritative(familyRecordName: familyName, type: .achievement, scope: scope),
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

    func cachedOrSeededAchievementCaches(for family: Family) -> [AchievementCache] {
        let familyName = family.id.recordName
        if let cache = cacheService {
            if let scope = DatabaseScopeResolver.resolvedScope(appState: appState) {
                if cache.isCacheAuthoritative(familyRecordName: familyName, type: .achievement, scope: scope) {
                    return cache.fetchAchievements(family: familyName).sorted { $0.name < $1.name }
                }
            } else {
                // WHY fail-closed: unknown scope serves cache only without guessing a database.
                logger.debug("Achievement cache read serving cache-only: unknown database scope for family '\(familyName, privacy: .private)'")
                let cached = cache.fetchAchievements(family: familyName).sorted { $0.name < $1.name }
                if !cached.isEmpty {
                    return cached
                }
            }
        }
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        return Self.defaultAchievements(for: familyRef).map { AchievementCache(from: $0) }.sorted { $0.name < $1.name }
    }

    func ensureDefaultAchievements(for family: Family) async -> [AchievementCache] {
        let familyName = family.id.recordName
        // WHY fail-closed: unknown scope serves cache only without guessing a database.
        guard let scope = DatabaseScopeResolver.resolvedScope(appState: appState) else {
            logger.debug("Achievement defaults serving cache-only: unknown database scope for family '\(familyName, privacy: .private)'")
            if let cache = cacheService {
                let cached = cache.fetchAchievements(family: familyName).sorted { $0.name < $1.name }
                if !cached.isEmpty {
                    return cached
                }
            }
            let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
            return Self.defaultAchievements(for: familyRef).map { AchievementCache(from: $0) }.sorted { $0.name < $1.name }
        }
        if let cache = cacheService {
            if cache.isCacheAuthoritative(familyRecordName: familyName, type: .achievement, scope: scope) {
                return cache.fetchAchievements(family: familyName).sorted { $0.name < $1.name }
            }
        }
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let defaults = Self.defaultAchievements(for: familyRef)
        if let handler = syncCoordinator?.hydrationHandler {
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
        return defaults.map { AchievementCache(from: $0) }.sorted { $0.name < $1.name }
    }

    // WHY: Bespoke fallback seeding default achievements when CloudKit empty — intentionally inline, not a single-type CacheFirst flow.
    func fetchAllDefinitions(family: Family) async throws -> [Achievement] {
        let familyName = family.id.recordName
        // WHY fail-closed: unknown scope serves cache only without guessing a database.
        guard let scope = DatabaseScopeResolver.resolvedScope(appState: appState) else {
            logger.debug("Achievement definitions serving cache-only: unknown database scope for family '\(familyName, privacy: .private)'")
            if let cache = cacheService {
                let cached = cache.fetchAchievements(family: familyName)
                if !cached.isEmpty {
                    return cached.map { $0.toAchievement(zoneID: family.id.zoneID) }
                }
            }
            let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
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
        if let cache = cacheService {
            let cached = cache.fetchAchievements(family: familyName)
            if cache.isCacheAuthoritative(familyRecordName: familyName, type: .achievement, scope: scope) {
                return cached.map { $0.toAchievement(zoneID: family.id.zoneID) }
            }
        }
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let predicate = NSPredicate(format: "family == %@", familyRef)
        do {
            let results = try await cloudKit.query(Achievement.self, predicate: predicate, in: family.id.zoneID)
            if !results.isEmpty {
                await syncCoordinator?.hydrationHandler.hydrateFromQuery(
                    models: results,
                    databaseScope: scope,
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

        // WHY fail-closed: unknown scope serves cache only without guessing a database.
        guard let scope = DatabaseScopeResolver.resolvedScope(appState: appState) else {
            logger.debug("Earned achievements serving cache-only: unknown database scope for family '\(primaryFamilyName, privacy: .private)'")
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

        if let cache = cacheService {
            if cache.isCacheAuthoritative(familyRecordName: primaryFamilyName, type: .profileAchievement, scope: scope) {
                return cache.fetchProfileAchievements(profileRecordName: profileName, family: primaryFamilyName)
                    .map { $0.toProfileAchievement(zoneID: profile.id.zoneID) }
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
            await syncCoordinator?.hydrationHandler.hydrateFromQuery(
                models: results,
                databaseScope: scope,
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
            case .streak7: 7
            case .streak30: 30
            default: nil
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
        logger.info("Evaluating trophies for \(profile.displayName, privacy: .private): \(statSummary, privacy: .public)")

        var awarded: [Achievement] = []
        for definition in unearned where isRequirementMet(definition: definition, stats: stats) {
            _ = try await award(definition, to: profile, family: family)
            awarded.append(definition)
        }

        await sendAwardNotifications(for: awarded, to: profile)

        // Forward newly awarded achievements to the celebration surface only on the earner's device.
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
            await syncCoordinator.sendPendingChanges()
        }
        logger
            .info(
                "Successfully awarded trophy '\(achievement.name, privacy: .public)' (id: \(achievement.id.recordName, privacy: .private)) to profile \(profile.displayName, privacy: .private)"
            )
        return row
    }
}

// MARK: - AchievementService Helpers

@MainActor
private extension AchievementService {
    // WHY: Multi-type stats aggregation with fallback-family and verification-status filtering — intentionally inline, not a CacheFirst flow.
    func fetchCompletedLogs(for profile: Profile, family: Family) async throws -> [QuestCompletion] {
        let profileName = profile.id.recordName
        let zoneID = profile.id.zoneID
        let primaryFamilyName = family.id.recordName
        let fallbackFamilyName = profile.family.recordID.recordName
        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)

        // WHY fail-closed: unknown scope serves cache only without guessing a database.
        guard let scope = DatabaseScopeResolver.resolvedScope(appState: appState) else {
            logger.debug("Completed logs serving cache-only: unknown database scope for family '\(primaryFamilyName, privacy: .private)'")
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

        if let cache = cacheService {
            let cachedLogs = cache.fetchQuestCompletions(family: primaryFamilyName)
                .filter { $0.completerRecordName == profileName }
            if cache.isCacheAuthoritative(familyRecordName: primaryFamilyName, type: .questCompletion, scope: scope) {
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
            await syncCoordinator?.hydrationHandler.hydrateFromQuery(
                models: questLogs,
                databaseScope: scope,
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

    // WHY: Multi-type stats aggregation with fallback-family fallback and fail-closed cache — intentionally inline, not a CacheFirst flow.
    func fetchLedgerEntries(for profile: Profile, family: Family) async throws -> [LedgerEntry] {
        let profileName = profile.id.recordName
        let zoneID = profile.id.zoneID
        let primaryFamilyName = family.id.recordName
        let fallbackFamilyName = profile.family.recordID.recordName
        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)

        // WHY fail-closed: unknown scope serves cache only without guessing a database.
        guard let scope = DatabaseScopeResolver.resolvedScope(appState: appState) else {
            logger.debug("Ledger entries serving cache-only: unknown database scope for family '\(primaryFamilyName, privacy: .private)'")
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

        if let cache = cacheService {
            let cachedLedger = cache.fetchLedgerEntries(
                profileRecordName: profileName,
                family: primaryFamilyName
            )
            if cache.isCacheAuthoritative(familyRecordName: primaryFamilyName, type: .ledgerEntry, scope: scope) {
                return cachedLedger.map { $0.toLedgerEntry(zoneID: zoneID) }
            }
        }

        do {
            let ledger = try await cloudKit.query(
                LedgerEntry.self,
                predicate: NSPredicate(format: "profile == %@", profileRef),
                in: zoneID
            )
            await syncCoordinator?.hydrationHandler.hydrateFromQuery(
                models: ledger,
                databaseScope: scope,
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

    // WHY: Multi-type stats aggregation with fallback-family and bespoke filtering — intentionally inline, not a CacheFirst flow.
    func fetchGoals(for profile: Profile, family: Family) async throws -> [Goal] {
        let profileName = profile.id.recordName
        let zoneID = profile.id.zoneID
        let primaryFamilyName = family.id.recordName
        let fallbackFamilyName = profile.family.recordID.recordName

        // WHY fail-closed: unknown scope serves cache only without guessing a database.
        guard let scope = DatabaseScopeResolver.resolvedScope(appState: appState) else {
            logger.debug("Goals serving cache-only: unknown database scope for family '\(primaryFamilyName, privacy: .private)'")
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

        if let cache = cacheService {
            let cached = cache.fetchGoals(family: primaryFamilyName)
                .filter { $0.profileRecordName == profileName }
            if cache.isCacheAuthoritative(familyRecordName: primaryFamilyName, type: .goal, scope: scope) {
                return cached.map { $0.toGoal(zoneID: zoneID) }
            }
        }

        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(format: "profile == %@", profileRef)
        do {
            let results = try await cloudKit.query(Goal.self, predicate: predicate, in: zoneID)
            await syncCoordinator?.hydrationHandler.hydrateFromQuery(
                models: results,
                databaseScope: scope,
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

    // WHY: Bespoke quest aggregation building dictionary with missing-fetch patching — intentionally inline, not a single-type CacheFirst flow.
    func fetchQuestCache(
        for completedLogs: [QuestCompletion],
        profileID: CKRecord.ID,
        familyName: String,
        zoneID: CKRecordZone.ID
    ) async throws -> [CKRecord.ID: Quest] {
        var questCache: [CKRecord.ID: Quest] = [:]

        // WHY fail-closed: unknown scope serves cache only without guessing a database.
        guard let scope = DatabaseScopeResolver.resolvedScope(appState: appState) else {
            logger.debug("Quest cache serving cache-only: unknown database scope for family '\(familyName, privacy: .private)'")
            if let cache = cacheService {
                for questCacheRow in cache.fetchQuests(family: familyName) {
                    let questObj = questCacheRow.toQuest(zoneID: zoneID)
                    questCache[questObj.id] = questObj
                }
            }
            return questCache
        }

        if let cache = cacheService {
            let cachedQuests = cache.fetchQuests(family: familyName)
            if cache.isCacheAuthoritative(familyRecordName: familyName, type: .quest, scope: scope) {
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
            await syncCoordinator?.hydrationHandler.hydrateFromQuery(
                models: assignedQuests,
                databaseScope: scope,
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
            await syncCoordinator?.hydrationHandler.hydrateFromQuery(
                models: fetchedMissing,
                databaseScope: scope,
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
        // WHY cache-only templates: stats stay cache-first so offline evaluation still resolves.
        let templatesByID: [String: QuestTemplate] = if let cache = cacheService {
            SpecificDaysHelper.templatesByID(cache: cache, familyName: family.id.recordName, zoneID: profile.id.zoneID)
        } else {
            [:]
        }

        var totalGold: Int64 = 0
        var dailyCompletionDates: Set<Int> = []
        var earlyBird = false
        var approvedCountByQuest: [CKRecord.ID: Int] = [:]

        for log in completedLogs {
            guard let quest = questCache[log.quest.recordID] else { continue }
            approvedCountByQuest[quest.id, default: 0] += 1

            dailyCompletionDates.insert(WeekMath.dayBucket(for: log.completedDate))

            let hour = Calendar.iso8601UTC.component(.hour, from: log.completedDate)
            if hour < AppConstants.Economy.earlyBirdHourCutoff {
                earlyBird = true
            }
        }

        for (questID, approvedCount) in approvedCountByQuest {
            if let quest = questCache[questID] {
                // WHY day count wins: legacy rows keep stale targetCount after template gains days.
                let effectiveTarget = SpecificDaysHelper.effectiveTarget(for: quest, templatesByID: templatesByID)
                totalGold += GoldCalculation.creditPennies(for: quest, approvedCount: approvedCount, effectiveTarget: effectiveTarget)
            }
        }

        let streakDays = longestConsecutiveStreak(in: dailyCompletionDates)
        let bestWeekly = computeBestWeeklyCompletion(
            profile: profile,
            approvedCountByQuest: approvedCountByQuest,
            questCache: questCache,
            templatesByID: templatesByID
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
}
