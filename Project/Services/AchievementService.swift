//
//  AchievementService.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import os

enum AchievementRequirement: String, CaseIterable, Codable, Sendable {
    case firstQuest
    case questCount10
    case questCount50
    case questCount100
    case weekly100
    case streak7
    case streak30
    case gold100
    case gold500
    case ledgerCount10
    case ledgerWeeks4
    case earlyBird9am
}

enum AchievementCategory: String, Codable, Sendable {
    case quest
    case streak
    case gold
    case special
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
    /// Injected alongside `toastManager` and forwarded awarded achievements
    /// from `evaluateAll`. `nil` in tests/legacy paths — celebrations are
    /// silently skipped when unset.
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
        let defaults = defaultAchievements(for: familyRef)

        if let cache = cacheService,
           cache.isCacheFresh(familyRecordName: familyName, type: .achievement)
        {
            let cached = cache.fetchAchievements(family: familyName)
            let cachedIDs = Set(cached.map(\.recordName))
            if defaults.allSatisfy({ cachedIDs.contains($0.id.recordName) }) {
                return
            }
        }

        let existing = try await fetchAllDefinitions(family: family)
        let existingIDs = Set(existing.map(\.id.recordName))

        let toSeed = defaults.filter { !existingIDs.contains($0.id.recordName) }

        for achievement in toSeed {
            cacheService?.upsertAchievement(achievement)
            let isOwner = appState.isZoneOwner
            syncCoordinator?.enqueueSave(recordID: achievement.id, isOwner: isOwner)
        }
    }

    private func defaultAchievements(for familyRef: CKRecord.Reference) -> [Achievement] {
        questAchievements(for: familyRef)
            + streakAchievements(for: familyRef)
            + financialAchievements(for: familyRef)
            + specialAchievements(for: familyRef)
    }

    private func questAchievements(for familyRef: CKRecord.Reference) -> [Achievement] {
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

    private func streakAchievements(for familyRef: CKRecord.Reference) -> [Achievement] {
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

    private func financialAchievements(for familyRef: CKRecord.Reference) -> [Achievement] {
        let zoneID = familyRef.recordID.zoneID
        return [
            Achievement(
                id: CKRecord.ID(recordName: "\(familyRef.recordID.recordName)-\(AchievementRequirement.gold100.rawValue)", zoneID: zoneID),
                name: "Fortune Hoarder",
                description: "Earn 100 gold lifetime",
                iconSystemName: "banknote.fill",
                category: AchievementCategory.gold,
                requirementType: AchievementRequirement.gold100,
                requirementValue: 100,
                family: familyRef
            ),
            Achievement(
                id: CKRecord.ID(recordName: "\(familyRef.recordID.recordName)-\(AchievementRequirement.gold500.rawValue)", zoneID: zoneID),
                name: "Fortune Magnate",
                description: "Earn 500 gold lifetime",
                iconSystemName: "banknote",
                category: AchievementCategory.gold,
                requirementType: AchievementRequirement.gold500,
                requirementValue: 500,
                family: familyRef
            )
        ]
    }

    private func specialAchievements(for familyRef: CKRecord.Reference) -> [Achievement] {
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
                id: CKRecord.ID(recordName: "\(familyRef.recordID.recordName)-\(AchievementRequirement.ledgerWeeks4.rawValue)", zoneID: zoneID),
                name: "Wise Spender",
                description: "Log spending for 4 weeks",
                iconSystemName: "book.closed.fill",
                category: AchievementCategory.special,
                requirementType: AchievementRequirement.ledgerWeeks4,
                requirementValue: 4,
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

    func fetchAllDefinitions(family: Family) async throws -> [Achievement] {
        let familyName = family.id.recordName
        if let cache = cacheService, cache.isCacheFresh(familyRecordName: familyName, type: .achievement) {
            let cached = cache.fetchAchievements(family: familyName)
            return cached.map { $0.toAchievement(zoneID: family.id.zoneID) }
        }
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let predicate = NSPredicate(format: "family == %@", familyRef)
        let results = try await cloudKit.query(Achievement.self, predicate: predicate, in: family.id.zoneID)
        cacheService?.upsertAchievements(results)
        return results
    }

    func fetchEarned(profile: Profile) async throws -> [ProfileAchievement] {
        let profileName = profile.id.recordName
        let familyName = profile.family.recordID.recordName
        if let cache = cacheService, cache.isCacheFresh(familyRecordName: familyName, type: .profileAchievement) {
            let cached = cache.fetchProfileAchievements(profileRecordName: profileName)
            return cached.map { $0.toProfileAchievement(zoneID: profile.id.zoneID) }
                .sorted { $0.earnedDate > $1.earnedDate }
        }

        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(format: "profile == %@", profileRef)
        let results = try await cloudKit.query(
            ProfileAchievement.self,
            predicate: predicate,
            in: profile.id.zoneID,
            sortDescriptors: [NSSortDescriptor(key: "earnedDate", ascending: false)]
        )
        cacheService?.upsertProfileAchievements(results)
        return results
    }

    @discardableResult
    func evaluateAll(for profile: Profile, family: Family) async throws -> [Achievement] {
        guard let acting = appState?.currentProfile, acting.id == profile.id || acting.role.isParent else {
            return []
        }

        let existingEarned = try await fetchEarned(profile: profile)
        let earnedAchievementIDs = Set(existingEarned.map(\.achievement.recordID.recordName))

        let allDefinitions = try await fetchAllDefinitions(family: family)
        let unearned = allDefinitions.filter { !earnedAchievementIDs.contains($0.id.recordName) }

        guard !unearned.isEmpty else { return [] }

        let stats = try await computeStats(for: profile, family: family)

        var awarded: [Achievement] = []
        for definition in unearned where isRequirementMet(definition: definition, stats: stats) {
            _ = try await award(definition, to: profile, family: family)
            awarded.append(definition)
        }

        // Notify trophy awards. Never `try?` — notification failures must be
        // logged (logger.error) so silent drops are observable; send is
        // best-effort, so failures are logged and the loop continues rather
        // than aborting the remaining awards.
        if let notificationService, !awarded.isEmpty {
            for achievement in awarded {
                do {
                    try await notificationService.send(
                        .trophyEarned,
                        to: profile,
                        title: "🏅 Trophy Earned!",
                        body: "You unlocked '\(achievement.name)'!"
                    )
                } catch {
                    logger
                        .error(
                            "Failed to send trophyEarned notification for achievement "
                                + "\(achievement.id.recordName, privacy: .private) to profile "
                                + "\(profile.id.recordName, privacy: .private): "
                                + "\(String(describing: error), privacy: .private)"
                        )
                }
            }
        }

        // Fire streak milestone notifications only when the matching
        // milestone achievement (.streak7 / .streak30) was newly awarded
        // in this pass. longestStreakDays is a lifetime best, so gating on
        // it directly would re-notify a hero whose best streak has plateaued
        // on every TrophyRoom open or verification.
        // Never `try?` — log failures explicitly; best-effort delivery continues
        // to the next threshold on error.
        if let notificationService {
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
                    logger
                        .error(
                            "Failed to send streakMilestone notification for "
                                + "\(streakDays)-day streak to profile "
                                + "\(profile.id.recordName, privacy: .private): "
                                + "\(String(describing: error), privacy: .private)"
                        )
                }
            }
        }

        // Forward the full set of newly awarded achievements (trophies and
        // streak milestones alike) to the celebration surface. The manager
        // decides per-item whether to present a fullscreen overlay or an
        // enhanced toast; streak milestones are distinguished inside
        // `CelebrationItem.isStreakMilestone` from `requirementType`.
        celebrationManager?.enqueue(achievements: awarded, for: profile)

        return awarded
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

        cacheService?.upsertProfileAchievement(row)
        let isOwner = appState?.isZoneOwner ?? false
        syncCoordinator?.enqueueSave(recordID: row.id, isOwner: isOwner)
        return row
    }

    private func fetchCompletedLogs(for profile: Profile) async throws -> [QuestCompletion] {
        let profileName = profile.id.recordName
        let zoneID = profile.id.zoneID
        let familyName = profile.family.recordID.recordName
        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)

        if let cache = cacheService,
           cache.isCacheFresh(familyRecordName: familyName, type: .questCompletion)
        {
            let cachedLogs = cache.fetchQuestCompletions(family: familyName)
                .filter { $0.completerRecordName == profileName }
            return cachedLogs
                .map { $0.toQuestCompletion(zoneID: zoneID) }
                .filter { $0.verificationStatus == .verified || $0.verificationStatus == .autoApproved }
        }

        let questLogs = try await cloudKit.query(
            QuestCompletion.self,
            predicate: NSPredicate(format: "completedBy == %@", profileRef),
            in: zoneID
        )
        cacheService?.upsertQuestCompletions(questLogs)
        return questLogs.filter {
            $0.verificationStatus == .verified || $0.verificationStatus == .autoApproved
        }
    }

    private func fetchLedgerEntries(for profile: Profile) async throws -> [LedgerEntry] {
        let profileName = profile.id.recordName
        let zoneID = profile.id.zoneID
        let familyName = profile.family.recordID.recordName
        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)

        if let cache = cacheService,
           cache.isCacheFresh(familyRecordName: familyName, type: .ledgerEntry)
        {
            let cachedLedger = cache.fetchLedgerEntries(
                profileRecordName: profileName,
                family: familyName
            )
            return cachedLedger.map { $0.toLedgerEntry(zoneID: zoneID) }
        }

        let ledger = try await cloudKit.query(
            LedgerEntry.self,
            predicate: NSPredicate(format: "profile == %@", profileRef),
            in: zoneID
        )
        cacheService?.upsertLedgerEntries(ledger)
        return ledger
    }

    private func fetchQuestCache(
        for completedLogs: [QuestCompletion],
        profileID: CKRecord.ID,
        familyName: String,
        zoneID: CKRecordZone.ID
    ) async throws -> [CKRecord.ID: Quest] {
        var questCache: [CKRecord.ID: Quest] = [:]

        if let cache = cacheService,
           cache.isCacheFresh(familyRecordName: familyName, type: .quest)
        {
            let cachedQuests = cache.fetchQuests(family: familyName)
            for questCacheRow in cachedQuests {
                let questObj = questCacheRow.toQuest(zoneID: zoneID)
                questCache[questObj.id] = questObj
            }
        } else {
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
                    cacheService?.upsertQuest(quest)
                }
            } catch {
                logger.error("Failed to query assigned quests for profile \(profileID.recordName, privacy: .private): \(error, privacy: .private)")
            }

            let missingQuestIDs = Set(completedLogs.map(\.quest.recordID)).subtracting(questCache.keys)
            for questID in missingQuestIDs {
                do {
                    let fetched = try await cloudKit.fetch(Quest.self, id: questID)
                    questCache[questID] = fetched
                    cacheService?.upsertQuest(fetched)
                } catch {
                    logger.debug("Failed to fetch quest \(questID.recordName, privacy: .private): \(error, privacy: .private)")
                }
            }
        }
        return questCache
    }

    private func computeStats(for profile: Profile, family _: Family) async throws -> ProfileStats {
        let completedLogs = try await fetchCompletedLogs(for: profile)
        let ledger = try await fetchLedgerEntries(for: profile)
        let questCache = try await fetchQuestCache(
            for: completedLogs,
            profileID: profile.id,
            familyName: profile.family.recordID.recordName,
            zoneID: profile.id.zoneID
        )

        var totalGold: Double = 0
        let calendar = Calendar.iso8601UTC
        var dailyCompletionDates: Set<DateComponents> = []
        var weekCompletionCounts: [Date: Int] = [:]
        var earlyBird = false
        var approvedCountByQuest: [CKRecord.ID: Int] = [:]

        for log in completedLogs {
            guard let quest = questCache[log.quest.recordID] else { continue }
            approvedCountByQuest[quest.id, default: 0] += 1

            let day = calendar.dateComponents([.year, .month, .day], from: log.completedDate)
            dailyCompletionDates.insert(day)
            weekCompletionCounts[quest.weekOf, default: 0] += 1

            let hour = calendar.component(.hour, from: log.completedDate)
            if hour < AppConstants.Economy.earlyBirdHourCutoff {
                earlyBird = true
            }
        }

        for (questID, approvedCount) in approvedCountByQuest {
            if let quest = questCache[questID] {
                totalGold += GoldCalculation.creditAsDouble(for: quest, approvedCount: approvedCount)
            }
        }

        let streakDays = longestConsecutiveStreak(in: dailyCompletionDates, calendar: calendar)
        let bestWeekly = computeBestWeeklyCompletion(
            profile: profile,
            approvedCountByQuest: approvedCountByQuest,
            questCache: questCache
        )

        var ledgerWeekRoots = Set<Date>()
        for entry in ledger {
            let monday = calendar.nextOrSameMonday(for: entry.date)
            ledgerWeekRoots.insert(monday)
        }

        return ProfileStats(
            questCount: completedLogs.count,
            bestWeeklyCompletion: bestWeekly,
            longestStreakDays: streakDays,
            totalGoldEarned: totalGold,
            ledgerCount: ledger.count,
            ledgerWeeksCount: ledgerWeekRoots.count,
            earlyBirdQualified: earlyBird
        )
    }

    private func computeBestWeeklyCompletion(
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

    private func longestConsecutiveStreak(in days: Set<DateComponents>, calendar: Calendar) -> Int {
        guard !days.isEmpty else { return 0 }

        let reconstructed: [Date] = days.compactMap { components -> Date? in
            calendar.date(from: components)
        }.sorted()
        var best = 1
        var run = 1
        for index in 1 ..< reconstructed.count {
            let prev = reconstructed[index - 1]
            let curr = reconstructed[index]
            let delta = calendar.dateComponents([.day], from: prev, to: curr).day ?? 0
            if delta == 1 {
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

    private func isRequirementMet(definition: Achievement, stats: ProfileStats) -> Bool {
        switch definition.requirementType {
        case AchievementRequirement.firstQuest:
            stats.questCount >= 1

        case AchievementRequirement.questCount10:
            stats.questCount >= 10

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

        case AchievementRequirement.gold100:
            stats.totalGoldEarned >= 100

        case AchievementRequirement.gold500:
            stats.totalGoldEarned >= 500

        case AchievementRequirement.ledgerCount10:
            stats.ledgerCount >= 10

        case AchievementRequirement.ledgerWeeks4:
            stats.ledgerWeeksCount >= 4

        case AchievementRequirement.earlyBird9am:
            stats.earlyBirdQualified
        }
    }
}

private extension Calendar {
    func nextOrSameMonday(for date: Date) -> Date {
        let comps = dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        var mondayComps = DateComponents()
        mondayComps.yearForWeekOfYear = comps.yearForWeekOfYear
        mondayComps.weekOfYear = comps.weekOfYear
        mondayComps.weekday = 2
        return self.date(from: mondayComps) ?? date
    }
}
