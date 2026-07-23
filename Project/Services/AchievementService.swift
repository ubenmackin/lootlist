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
    init(cloudKit: CloudKitService) {
        self.cloudKit = cloudKit
    }

    private let cloudKit: CloudKitService

    func seedDefaultAchievements(family: Family) async throws {
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let existing = try await fetchAllDefinitions(family: family)
        let existingNames = Set(existing.map(\.name))

        let toSeed = defaultAchievements(for: familyRef)
            .filter { !existingNames.contains($0.name) }

        for achievement in toSeed {
            _ = try await cloudKit.save(achievement)
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
                name: "Gold Hoarder",
                description: "Earn $100 lifetime",
                iconSystemName: "coins",
                category: AchievementCategory.gold,
                requirementType: AchievementRequirement.gold100,
                requirementValue: 100,
                family: familyRef
            ),
            Achievement(
                name: "Gold Magnate",
                description: "Earn $500 lifetime",
                iconSystemName: "dollarsign.circle.fill",
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
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let predicate = NSPredicate(format: "family == %@", familyRef)
        return try await cloudKit.query(Achievement.self, predicate: predicate)
    }

    func fetchEarned(profile: Profile) async throws -> [ProfileAchievement] {
        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)
        let predicate = NSPredicate(format: "profile == %@", profileRef)
        return try await cloudKit.query(
            ProfileAchievement.self,
            predicate: predicate,
            sortDescriptors: [NSSortDescriptor(key: "earnedDate", ascending: false)]
        )
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
        return try await cloudKit.save(row)
    }

    private func computeStats(for profile: Profile, family _: Family) async throws -> ProfileStats {
        let profileRef = CKRecord.Reference(recordID: profile.id, action: .none)

        let questLogs = try await cloudKit.query(
            QuestCompletion.self,
            predicate: NSPredicate(format: "completedBy == %@", profileRef)
        )
        let completedLogs = questLogs.filter {
            $0.verificationStatus == .verified || $0.verificationStatus == .autoApproved
        }

        let ledger = try await cloudKit.query(
            LedgerEntry.self,
            predicate: NSPredicate(format: "profile == %@", profileRef)
        )

        let questIDs = Set(completedLogs.map(\.quest.recordID))
        var questCache: [CKRecord.ID: Quest] = [:]
        if !questIDs.isEmpty {
            let idArray = Array(questIDs)
            let fetched = try await cloudKit.query(
                Quest.self,
                predicate: NSPredicate(format: "recordID IN %@", idArray)
            )
            for quest in fetched {
                questCache[quest.id] = quest
            }
        }

        var totalGold: Double = 0
        let calendar = Calendar.iso8601UTC
        var dailyCompletionDates: Set<DateComponents> = []
        var weekCompletionCounts: [Date: Int] = [:]
        var earlyBird = false

        for log in completedLogs {
            guard let quest = questCache[log.quest.recordID] else { continue }
            totalGold += quest.goldReward

            let day = calendar.dateComponents([.year, .month, .day], from: log.completedDate)
            dailyCompletionDates.insert(day)

            weekCompletionCounts[quest.weekOf, default: 0] += 1

            let hour = calendar.component(.hour, from: log.completedDate)
            if hour < 9 {
                earlyBird = true
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
