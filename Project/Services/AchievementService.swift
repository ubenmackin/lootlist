//
//  AchievementService.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation

enum AchievementRequirement: String, Codable, Sendable {
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
    var cacheService: CacheService?

    var toastManager: ToastManager?

    init(cloudKit: any CloudKitServiceProtocol, cacheService: CacheService? = nil) {
        self.cloudKit = cloudKit
        self.cacheService = cacheService
    }

    private let cloudKit: any CloudKitServiceProtocol

    func seedDefaultAchievements(family: Family) async throws {
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let existing = try await fetchAllDefinitions(family: family)
        let existingNames = Set(existing.map(\.name))

        let toSeed = defaultAchievements(for: familyRef)
            .filter { !existingNames.contains($0.name) }

        for achievement in toSeed {
            let saved = try await cloudKit.save(achievement)
            cacheService?.upsertAchievement(saved)
        }
    }

    private func defaultAchievements(for familyRef: CKRecord.Reference) -> [Achievement] {
        questAchievements(for: familyRef)
            + streakAchievements(for: familyRef)
            + financialAchievements(for: familyRef)
            + specialAchievements(for: familyRef)
    }

    private func questAchievements(for familyRef: CKRecord.Reference) -> [Achievement] {
        [
            Achievement(
                name: "First Steps",
                description: "Complete your first quest",
                iconSystemName: "shoeprints.fill",
                category: AchievementCategory.quest,
                requirementType: AchievementRequirement.firstQuest,
                requirementValue: 1,
                family: familyRef
            ),
            Achievement(
                name: "Questing Squire",
                description: "Complete 10 quests",
                iconSystemName: "flag.checkered",
                category: AchievementCategory.quest,
                requirementType: AchievementRequirement.questCount10,
                requirementValue: 10,
                family: familyRef
            ),
            Achievement(
                name: "Quest Knight",
                description: "Complete 50 quests",
                iconSystemName: "figure.fencing",
                category: AchievementCategory.quest,
                requirementType: AchievementRequirement.questCount50,
                requirementValue: 50,
                family: familyRef
            ),
            Achievement(
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
        [
            Achievement(
                name: "Week Warrior",
                description: "Complete all quests in a week",
                iconSystemName: "calendar.badge.checkmark",
                category: AchievementCategory.special,
                requirementType: AchievementRequirement.weekly100,
                requirementValue: 1,
                family: familyRef
            ),
            Achievement(
                name: "Iron Will",
                description: "7-day streak",
                iconSystemName: "flame.fill",
                category: AchievementCategory.streak,
                requirementType: AchievementRequirement.streak7,
                requirementValue: 7,
                family: familyRef
            ),
            Achievement(
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
        [
            Achievement(
                name: "Fortune Hoarder",
                description: "Earn \(CurrencyFormatter.string(100)) lifetime",
                iconSystemName: "coins",
                category: AchievementCategory.gold,
                requirementType: AchievementRequirement.gold100,
                requirementValue: 100,
                family: familyRef
            ),
            Achievement(
                name: "Fortune Magnate",
                description: "Earn \(CurrencyFormatter.string(500)) lifetime",
                iconSystemName: "banknote",
                category: AchievementCategory.gold,
                requirementType: AchievementRequirement.gold500,
                requirementValue: 500,
                family: familyRef
            )
        ]
    }

    private func specialAchievements(for familyRef: CKRecord.Reference) -> [Achievement] {
        [
            Achievement(
                name: "Chronicler",
                description: "Log 10 spending entries",
                iconSystemName: "scroll.fill",
                category: AchievementCategory.special,
                requirementType: AchievementRequirement.ledgerCount10,
                requirementValue: 10,
                family: familyRef
            ),
            Achievement(
                name: "Wise Spender",
                description: "Log spending for 4 weeks",
                iconSystemName: "book.closed.fill",
                category: AchievementCategory.special,
                requirementType: AchievementRequirement.ledgerWeeks4,
                requirementValue: 4,
                family: familyRef
            ),
            Achievement(
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
        if let cache = cacheService {
            let familyName = family.id.recordName
            let cached = cache.fetchAchievements(family: familyName)
            if !cached.isEmpty, cache.isCacheFresh(familyRecordName: familyName, type: .achievement) {
                return cached.map { $0.toAchievement(zoneID: cloudKit.resolvedZoneID) }
            }
        }
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let predicate = NSPredicate(format: "family == %@", familyRef)
        let results = try await cloudKit.query(Achievement.self, predicate: predicate)
        cacheService?.upsertAchievements(results)
        return results
    }

    func fetchEarned(profile: Profile) async throws -> [ProfileAchievement] {
        if let cache = cacheService {
            let profileName = profile.id.recordName
            let familyName = profile.family.recordID.recordName
            let cached = cache.fetchProfileAchievements(profileRecordName: profileName)
            if !cached.isEmpty, cache.isCacheFresh(familyRecordName: familyName, type: .profileAchievement) {
                return cached.map { $0.toProfileAchievement(zoneID: cloudKit.resolvedZoneID) }
                    .sorted { $0.earnedDate > $1.earnedDate }
            }
        }

        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(format: "profile == %@", profileRef)
        let results = try await cloudKit.query(
            ProfileAchievement.self,
            predicate: predicate,
            sortDescriptors: [NSSortDescriptor(key: "earnedDate", ascending: false)]
        )
        cacheService?.upsertProfileAchievements(results)
        return results
    }

    func evaluateAll(for profile: Profile, family: Family) async throws -> [Achievement] {
        let definitions = try await fetchAllDefinitions(family: family)
        guard !definitions.isEmpty else { return [] }

        let earned = try await fetchEarned(profile: profile)
        let earnedIDs = Set(earned.map(\.achievement.recordID))

        let stats = try await computeStats(for: profile, family: family)

        var awarded: [Achievement] = []
        for definition in definitions where !earnedIDs.contains(definition.id) {
            if isRequirementMet(definition: definition, stats: stats) {
                _ = try await award(definition, to: profile, family: family)
                awarded.append(definition)
            }
        }
        return awarded
    }

    func award(_ achievement: Achievement,
               to profile: Profile,
               family: Family) async throws -> ProfileAchievement
    {
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let row = ProfileAchievement(
            achievement: CKRecord.Reference(recordID: achievement.id, action: .none),
            profile: CKRecord.Reference(recordID: profile.id, action: .none),
            family: familyRef
        )
        let name = row.id.recordName
        let snapshot = cacheService?.fetchProfileAchievements(profileRecordName: profile.id.recordName)
            .first(where: { $0.recordName == name })
        let preMutationChangeTag = snapshot?.changeTag
        // changeTag rehydrated from cache row per toX(zoneID:), safe for use in ConcurrentEditDetector.
        let snapshotPA: ProfileAchievement? = snapshot?.toProfileAchievement(zoneID: cloudKit.resolvedZoneID)

        // Register the optimistic window so a background sync skips this row.
        let registry = cacheService?.inFlightRegistry
        await registry?.register(name)

        cacheService?.upsertProfileAchievement(row)
        do {
            let saved = try await cloudKit.save(row)
            cacheService?.upsertProfileAchievement(saved)
            await registry?.deregister(name)
            return saved
        } catch {
            let concurrentEditDetected = ConcurrentEditDetector.detectConcurrentEdit(
                preMutationChangeTag: preMutationChangeTag,
                fetchCurrent: { self.cacheService?.fetchProfileAchievements(profileRecordName: profile.id.recordName)
                    .first(where: { $0.recordName == name })?.changeTag
                },
                error: error
            )

            if concurrentEditDetected {
                toastManager?.show(
                    message: "Data was modified by another device. Refresh to see the latest.",
                    type: .warning
                )
                if let fresh = try? await cloudKit.fetch(ProfileAchievement.self, id: row.id) {
                    cacheService?.upsertProfileAchievement(fresh)
                } else if let snapshotPA {
                    cacheService?.upsertProfileAchievement(snapshotPA)
                } else {
                    cacheService?.invalidateProfileAchievement(recordName: name)
                }
            } else {
                if let snapshotPA {
                    cacheService?.upsertProfileAchievement(snapshotPA)
                } else {
                    cacheService?.invalidateProfileAchievement(recordName: name)
                }
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                toastManager?.show(message: message, type: .error)
            }
            await registry?.deregister(name)
            throw error
        }
    }

    private func computeStats(for profile: Profile, family _: Family) async throws -> ProfileStats {
        let profileName = profile.id.recordName
        let zoneID = cloudKit.resolvedZoneID

        var completedLogs: [QuestCompletion] = []
        var ledger: [LedgerEntry] = []
        var questCache: [CKRecord.ID: Quest] = [:]

        if let cache = cacheService {
            let cachedLogs = cache.fetchQuestCompletions(family: profile.family.recordID.recordName)
                .filter { $0.completerRecordName == profileName }
            completedLogs = cachedLogs
                .map { $0.toQuestCompletion(zoneID: zoneID) }
                .filter { $0.verificationStatus == .verified || $0.verificationStatus == .autoApproved }

            let cachedLedger = cache.fetchLedgerEntries(
                profileRecordName: profileName,
                family: profile.family.recordID.recordName
            )
            ledger = cachedLedger.map { $0.toLedgerEntry(zoneID: zoneID) }

            let cachedQuests = cache.fetchQuests(family: profile.family.recordID.recordName)
            for questCacheRow in cachedQuests {
                let questObj = questCacheRow.toQuest(zoneID: zoneID)
                questCache[questObj.id] = questObj
            }
        } else {
            let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
            let questLogs = try await cloudKit.query(
                QuestCompletion.self,
                predicate: NSPredicate(format: "completedBy == %@", profileRef)
            )
            completedLogs = questLogs.filter {
                $0.verificationStatus == .verified || $0.verificationStatus == .autoApproved
            }

            ledger = try await cloudKit.query(
                LedgerEntry.self,
                predicate: NSPredicate(format: "profile == %@", profileRef)
            )

            let questIDs = Set(completedLogs.map(\.quest.recordID))
            for questID in questIDs {
                if let fetched = try? await cloudKit.fetch(Quest.self, id: questID) {
                    questCache[questID] = fetched
                }
            }
        }

        var totalGold: Double = 0
        let calendar = Calendar.iso8601UTC
        var dailyCompletionDates: Set<DateComponents> = []
        var weekCompletionCounts: [Date: Int] = [:]
        var earlyBird = false

        // Track per-quest approved counts so the gold credit can be
        // computed once per quest through the shared `GoldCalculation`
        // helper — the same one `TreasuryService.sumGold` uses — instead of
        // adding the full `goldReward` for every log. The proration is
        // per-quest (approvedCount per quest * goldReward / targetCount,
        // capped by `isAllOrNothing`), so the helper is invoked after the
        // loop with the full approved count for each quest.
        var approvedCountByQuest: [CKRecord.ID: Int] = [:]

        for log in completedLogs {
            // Cache-first: fall back to CK only on genuine cache miss.
            if questCache[log.quest.recordID] == nil {
                if let fetched = try? await cloudKit.fetch(Quest.self, id: log.quest.recordID) {
                    questCache[log.quest.recordID] = fetched
                }
            }
            guard let quest = questCache[log.quest.recordID] else { continue }
            approvedCountByQuest[quest.id, default: 0] += 1

            let day = calendar.dateComponents([.year, .month, .day], from: log.completedDate)
            dailyCompletionDates.insert(day)

            weekCompletionCounts[quest.weekOf, default: 0] += 1

            let hour = calendar.component(.hour, from: log.completedDate)
            if hour < 9 {
                earlyBird = true
            }
        }

        for (questID, approvedCount) in approvedCountByQuest {
            if let quest = questCache[questID] {
                totalGold += GoldCalculation.creditAsDouble(for: quest,
                                                            approvedCount: approvedCount)
            }
        }

        let streakDays = longestConsecutiveStreak(in: dailyCompletionDates, calendar: calendar)

        let bestWeekly: Double = weekCompletionCounts.values.contains { $0 >= 5 } ? 1.0 : 0.0

        let ledgerCount = ledger.count
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
            ledgerCount: ledgerCount,
            ledgerWeeksCount: ledgerWeekRoots.count,
            earlyBirdQualified: earlyBird
        )
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
