//
//  SampleData.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation

@MainActor
enum SampleData {
    static let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")

    static let familyID = CKRecord.ID(recordName: "fam_garcia", zoneID: zoneID)
    static let familyRef = CKRecord.Reference(recordID: familyID, action: .none)

    static let parentUserID = CKRecord.ID(recordName: "user_dad", zoneID: zoneID)
    static let hero1UserID = CKRecord.ID(recordName: "user_maya", zoneID: zoneID)
    static let hero2UserID = CKRecord.ID(recordName: "user_leo", zoneID: zoneID)

    static let hero1ID = CKRecord.ID(recordName: "hero_maya", zoneID: zoneID)
    static let hero1Ref = CKRecord.Reference(recordID: hero1ID, action: .none)

    static let hero2ID = CKRecord.ID(recordName: "hero_leo", zoneID: zoneID)
    static let hero2Ref = CKRecord.Reference(recordID: hero2ID, action: .none)

    static let parentID = CKRecord.ID(recordName: "parent_dad", zoneID: zoneID)
    static let parentRef = CKRecord.Reference(recordID: parentID, action: .none)

    // MARK: - Family & Profiles

    static var family: Family {
        Family(
            name: "The Garcia Family",
            createdBy: parentUserID,
            payoutPolicy: .perQuest,
            id: familyID
        )
    }

    static var heroProfile: Profile {
        Profile(
            displayName: "Maya",
            role: .hero,
            iCloudUserID: hero1UserID,
            family: familyRef,
            avatarEmoji: "🦊",
            splitPercentSpend: 50,
            splitPercentShort: 30,
            splitPercentLong: 20,
            interestEnabled: true,
            interestBucket: BucketKind.shortTermSave.rawValue,
            interestRateBps: 500,
            interestIsCompound: false,
            matchEnabled: true,
            matchRateBps: 5000,
            matchMonthlyCapPennies: 1000,
            id: hero1ID
        )
    }

    static var secondHeroProfile: Profile {
        Profile(
            displayName: "Leo",
            role: .hero,
            iCloudUserID: hero2UserID,
            family: familyRef,
            avatarEmoji: "🐯",
            splitPercentSpend: 70,
            splitPercentShort: 20,
            splitPercentLong: 10,
            id: hero2ID
        )
    }

    static var parentProfile: Profile {
        Profile(
            displayName: "Dad",
            role: .guildMaster,
            iCloudUserID: parentUserID,
            family: familyRef,
            avatarEmoji: "🧔",
            id: parentID
        )
    }

    // MARK: - Templates & Quests

    struct SampleQuestData {
        let templates: [QuestTemplate]
        let quests: [Quest]
        let completions: [QuestCompletion]
        let goals: [Goal]
    }

    private struct TemplateSeed {
        let name: String
        let desc: String
        let gold: Double
        let xp: Int
        let sched: QuestSchedule
        let approval: ApprovalMode
    }

    static func createTemplatesAndQuests(boardClaims: Int = 0) -> SampleQuestData {
        let currentWeek = WeekMath.startOfWeek(for: Date(), payoutDay: .sunday)

        let templatesData: [TemplateSeed] = [
            TemplateSeed(name: "Tidy Room", desc: "Tidy bedroom floor", gold: 5.00, xp: 50, sched: .weeklyFlexible, approval: .autoApprove),
            TemplateSeed(name: "Do Homework", desc: "30 minutes of homework", gold: 7.50, xp: 75, sched: .weeklyFlexible, approval: .autoApprove),
            TemplateSeed(name: "Help with Dishes", desc: "Load and unload dishwasher", gold: 4.50, xp: 45, sched: .weeklyFlexible, approval: .parentVerify)
        ]

        var templates: [QuestTemplate] = []
        var quests: [Quest] = []
        var completions: [QuestCompletion] = []

        for (index, item) in templatesData.enumerated() {
            let tID = CKRecord.ID(recordName: "template_\(index + 1)", zoneID: zoneID)
            let templateRef = CKRecord.Reference(recordID: tID, action: .none)

            let template = QuestTemplate(
                name: item.name, description: item.desc,
                defaultGold: item.gold, xpReward: item.xp,
                scheduleType: item.sched, specificDays: [],
                isAllOrNothing: false, approvalMode: item.approval,
                createdBy: parentRef, family: familyRef, id: tID
            )
            templates.append(template)

            let qID = CKRecord.ID(recordName: "quest_hero1_\(index + 1)", zoneID: zoneID)
            let questRef = CKRecord.Reference(recordID: qID, action: .none)
            let quest = Quest(
                template: templateRef, assignee: hero1Ref,
                goldReward: item.gold, xpReward: item.xp,
                scheduleType: item.sched, isAllOrNothing: false,
                approvalMode: item.approval, weekOf: currentWeek,
                createdBy: parentRef, family: familyRef,
                name: item.name, descriptionText: item.desc, id: qID
            )
            quests.append(quest)

            if index < 2 {
                let cID = CKRecord.ID(recordName: "completion_\(index + 1)", zoneID: zoneID)
                let comp = QuestCompletion(
                    quest: questRef, completedBy: hero1Ref,
                    approvalMode: .autoApprove, weekOf: currentWeek,
                    family: familyRef, id: cID
                )
                completions.append(comp)
            } else if item.approval == .parentVerify {
                let cID = CKRecord.ID(recordName: "completion_\(index + 1)", zoneID: zoneID)
                let comp = QuestCompletion(
                    quest: questRef, completedBy: hero1Ref,
                    approvalMode: .parentVerify, weekOf: currentWeek,
                    family: familyRef, id: cID
                )
                completions.append(comp)
            }
        }

        let (boardTemplates, boardQuests) = createBoardQuests(currentWeek: currentWeek, claims: boardClaims)
        templates.append(contentsOf: boardTemplates)
        quests.append(contentsOf: boardQuests)

        let goals = createSampleGoals()

        return SampleQuestData(templates: templates, quests: quests, completions: completions, goals: goals)
    }

    private struct BoardQuestSeed {
        let recordSuffix: String
        let name: String
        let desc: String
        let gold: Double
        let xp: Int
    }

    /// The first `claims` board quests are pre-claimed by the primary hero so
    /// HeroBoardView renders claimed and unclaimed sections deterministically.
    private static func createBoardQuests(currentWeek: Date, claims: Int = 0) -> ([QuestTemplate], [Quest]) {
        let seeds: [BoardQuestSeed] = [
            BoardQuestSeed(recordSuffix: "dog", name: "Walk the Dog", desc: "Take the dog for a walk around the block", gold: 3.00, xp: 30),
            BoardQuestSeed(recordSuffix: "vacuum", name: "Vacuum Living Room", desc: "Vacuum the living room carpet and corners", gold: 4.00, xp: 40),
            BoardQuestSeed(recordSuffix: "plants", name: "Water Plants", desc: "Water the indoor plants in the living room and kitchen", gold: 2.00, xp: 20)
        ]

        var templates: [QuestTemplate] = []
        var quests: [Quest] = []

        for (index, seed) in seeds.enumerated() {
            let tID = CKRecord.ID(recordName: "template_board_\(seed.recordSuffix)", zoneID: zoneID)
            let templateRef = CKRecord.Reference(recordID: tID, action: .none)
            let template = QuestTemplate(
                name: seed.name, description: seed.desc,
                defaultGold: seed.gold, xpReward: seed.xp,
                scheduleType: .weeklyFlexible,
                createdBy: parentRef, family: familyRef, id: tID
            )
            templates.append(template)

            // Board quests carry the placeholder assignee so isBoardQuest
            // recognizes them; ownership rides the claim fields only.
            let boardAssigneeRef = CKRecord.Reference(
                recordID: CKRecord.ID(
                    recordName: HeroBoardService.boardAssigneeRecordName,
                    zoneID: zoneID
                ),
                action: .none
            )
            let isClaimed = index < claims
            let quest = Quest(
                template: templateRef, assignee: boardAssigneeRef,
                goldReward: seed.gold, xpReward: seed.xp,
                scheduleType: .weeklyFlexible, weekOf: currentWeek,
                createdBy: parentRef, family: familyRef,
                name: seed.name, descriptionText: seed.desc,
                claimedByProfileRecordName: isClaimed ? hero1ID.recordName : nil,
                claimedAt: isClaimed ? currentWeek.addingTimeInterval(86400) : nil,
                id: CKRecord.ID(recordName: "quest_board_\(seed.recordSuffix)", zoneID: zoneID)
            )
            quests.append(quest)
        }

        return (templates, quests)
    }

    // MARK: - Goals

    static func createSampleGoals() -> [Goal] {
        let now = Date()
        return [
            // Maya's goals
            Goal(
                profile: hero1Ref,
                family: familyRef,
                bucketKind: .shortTermSave,
                name: "Art Supplies",
                emojiIcon: "🎨",
                targetAmountPennies: 2500,
                createdAt: now.addingTimeInterval(-86400 * 7),
                id: CKRecord.ID(recordName: "goal_maya_art", zoneID: zoneID)
            ),
            Goal(
                profile: hero1Ref,
                family: familyRef,
                bucketKind: .longTermSave,
                name: "Nintendo Game",
                emojiIcon: "🎮",
                targetAmountPennies: 6000,
                createdAt: now.addingTimeInterval(-86400 * 6),
                id: CKRecord.ID(recordName: "goal_maya_nintendo", zoneID: zoneID)
            ),
            Goal(
                profile: hero1Ref,
                family: familyRef,
                bucketKind: .longTermSave,
                name: "New Bike",
                emojiIcon: "🚲",
                targetAmountPennies: 12000,
                createdAt: now.addingTimeInterval(-86400 * 5),
                id: CKRecord.ID(recordName: "goal_maya_bike", zoneID: zoneID)
            ),
            // Leo's goals
            Goal(
                profile: hero2Ref,
                family: familyRef,
                bucketKind: .shortTermSave,
                name: "LEGO Set",
                emojiIcon: "🧱",
                targetAmountPennies: 4000,
                createdAt: now.addingTimeInterval(-86400 * 4),
                id: CKRecord.ID(recordName: "goal_leo_lego", zoneID: zoneID)
            ),
            Goal(
                profile: hero2Ref,
                family: familyRef,
                bucketKind: .longTermSave,
                name: "Skateboard",
                emojiIcon: "🛹",
                targetAmountPennies: 8000,
                createdAt: now.addingTimeInterval(-86400 * 3),
                id: CKRecord.ID(recordName: "goal_leo_skateboard", zoneID: zoneID)
            )
        ]
    }

    // MARK: - Ledger Entries

    static func createLedgerEntries() -> [LedgerEntry] {
        let now = Date()
        return [
            // Quest reward entries with bucket attribution
            LedgerEntry(
                profile: hero1Ref,
                amount: 5.00,
                description: "Tidy Room — quest reward",
                date: now.addingTimeInterval(-86400 * 3),
                source: "quest",
                bucketKind: BucketKind.spend.rawValue,
                family: familyRef,
                id: CKRecord.ID(recordName: "ledger_qst_maya_spend", zoneID: zoneID)
            ),
            LedgerEntry(
                profile: hero1Ref,
                amount: 5.00,
                description: "Do Homework — quest reward",
                date: now.addingTimeInterval(-86400 * 2),
                source: "quest",
                bucketKind: BucketKind.shortTermSave.rawValue,
                family: familyRef,
                id: CKRecord.ID(recordName: "ledger_qst_maya_short", zoneID: zoneID)
            ),
            LedgerEntry(
                profile: hero2Ref,
                amount: 5.00,
                description: "Tidy Room — quest reward",
                date: now.addingTimeInterval(-86400 * 1),
                source: "quest",
                bucketKind: BucketKind.longTermSave.rawValue,
                family: familyRef,
                id: CKRecord.ID(recordName: "ledger_qst_leo_long", zoneID: zoneID)
            ),
            LedgerEntry(
                profile: hero1Ref,
                amount: 4.00,
                description: "Quest reward — Long-Term Save",
                date: now.addingTimeInterval(-86400 * 1),
                source: "quest",
                bucketKind: BucketKind.longTermSave.rawValue,
                family: familyRef,
                id: CKRecord.ID(recordName: "ledger_qst_maya_long", zoneID: zoneID)
            ),
            // Manual spending entries with bucket attribution
            LedgerEntry(
                profile: hero1Ref,
                amount: -2.50,
                description: "Candy from corner store",
                date: now.addingTimeInterval(-3600 * 5),
                source: "manual",
                bucketKind: BucketKind.spend.rawValue,
                family: familyRef,
                id: CKRecord.ID(recordName: "ledger_man_maya_candy", zoneID: zoneID)
            ),
            LedgerEntry(
                profile: hero2Ref,
                amount: -1.75,
                description: "Vending machine snack",
                date: now.addingTimeInterval(-3600 * 3),
                source: "manual",
                bucketKind: BucketKind.spend.rawValue,
                family: familyRef,
                id: CKRecord.ID(recordName: "ledger_man_leo_snack", zoneID: zoneID)
            ),
            // Interest entries for Maya
            LedgerEntry(
                profile: hero1Ref,
                amount: 0.15,
                description: "Monthly interest — Short-Term Save",
                date: now.addingTimeInterval(-86400 * 15),
                source: "interest",
                bucketKind: BucketKind.shortTermSave.rawValue,
                family: familyRef,
                id: CKRecord.ID(recordName: "ledger_int_maya_aug", zoneID: zoneID)
            ),
            // Match entry for Maya (parent match on goal contribution)
            LedgerEntry(
                profile: hero1Ref,
                amount: 2.50,
                description: "Parent match — Art Supplies goal",
                date: now.addingTimeInterval(-86400 * 6),
                source: "match",
                bucketKind: BucketKind.shortTermSave.rawValue,
                family: familyRef,
                id: CKRecord.ID(recordName: "ledger_mat_maya_art", zoneID: zoneID)
            )
        ]
    }

    static func createAllowancePeriods() -> [AllowancePeriod] {
        let currentWeek = WeekMath.startOfWeek(for: Date(), payoutDay: .sunday)
        let week1Ago = Calendar.iso8601UTC.date(byAdding: .day, value: -7, to: currentWeek) ?? currentWeek.addingTimeInterval(-86400 * 7)
        let week2Ago = Calendar.iso8601UTC.date(byAdding: .day, value: -14, to: currentWeek) ?? currentWeek.addingTimeInterval(-86400 * 14)
        let week3Ago = Calendar.iso8601UTC.date(byAdding: .day, value: -21, to: currentWeek) ?? currentWeek.addingTimeInterval(-86400 * 21)

        let paid1 = Calendar.iso8601UTC.date(byAdding: .day, value: 6, to: week1Ago) ?? week1Ago.addingTimeInterval(86400 * 6)
        let paid2 = Calendar.iso8601UTC.date(byAdding: .day, value: 6, to: week2Ago) ?? week2Ago.addingTimeInterval(86400 * 6)
        let paid3 = Calendar.iso8601UTC.date(byAdding: .day, value: 6, to: week3Ago) ?? week3Ago.addingTimeInterval(86400 * 6)

        return [
            // Maya's past payouts
            AllowancePeriod(
                weekOf: week1Ago,
                profile: hero1Ref,
                status: .paid,
                totalEarned: 12.50,
                questsCompleted: 5,
                questsTotal: 5,
                paidDate: paid1,
                paidAmount: 12.50,
                family: familyRef,
                id: CKRecord.ID(recordName: "allowance_maya_w1", zoneID: zoneID)
            ),
            AllowancePeriod(
                weekOf: week2Ago,
                profile: hero1Ref,
                status: .paid,
                totalEarned: 10.00,
                questsCompleted: 4,
                questsTotal: 5,
                paidDate: paid2,
                paidAmount: 10.00,
                family: familyRef,
                id: CKRecord.ID(recordName: "allowance_maya_w2", zoneID: zoneID)
            ),
            AllowancePeriod(
                weekOf: week3Ago,
                profile: hero1Ref,
                status: .paid,
                totalEarned: 15.00,
                questsCompleted: 6,
                questsTotal: 6,
                paidDate: paid3,
                paidAmount: 15.00,
                family: familyRef,
                id: CKRecord.ID(recordName: "allowance_maya_w3", zoneID: zoneID)
            ),
            // Leo's past payouts
            AllowancePeriod(
                weekOf: week1Ago,
                profile: hero2Ref,
                status: .paid,
                totalEarned: 8.00,
                questsCompleted: 3,
                questsTotal: 4,
                paidDate: paid1,
                paidAmount: 8.00,
                family: familyRef,
                id: CKRecord.ID(recordName: "allowance_leo_w1", zoneID: zoneID)
            ),
            AllowancePeriod(
                weekOf: week2Ago,
                profile: hero2Ref,
                status: .paid,
                totalEarned: 10.00,
                questsCompleted: 4,
                questsTotal: 4,
                paidDate: paid2,
                paidAmount: 10.00,
                family: familyRef,
                id: CKRecord.ID(recordName: "allowance_leo_w2", zoneID: zoneID)
            )
        ]
    }

    // MARK: - Achievements

    static func createAchievements() -> ([Achievement], [ProfileAchievement]) {
        let defaultAchs = questCountAchievements()
            + weeklyAndStreakAchievements()
            + goalAchievements()
            + specialAchievements()

        let profileAchs = [
            ProfileAchievement(
                achievement: CKRecord.Reference(recordID: CKRecord.ID(recordName: "ach_first_quest", zoneID: zoneID), action: .none),
                profile: hero1Ref,
                earnedDate: Date().addingTimeInterval(-86400 * 5),
                family: familyRef,
                id: CKRecord.ID(recordName: "pach_first_quest", zoneID: zoneID)
            )
        ]

        return (defaultAchs, profileAchs)
    }

    private static func questCountAchievements() -> [Achievement] {
        [
            Achievement(
                name: "First Quest Complete",
                description: "Complete your first quest",
                iconSystemName: "1.circle.fill",
                category: .quest,
                requirementType: .firstQuest,
                requirementValue: 1,
                family: familyRef,
                id: CKRecord.ID(recordName: "ach_first_quest", zoneID: zoneID)
            ),
            Achievement(
                name: "Quest Novice",
                description: "Complete 10 quests",
                iconSystemName: "10.circle.fill",
                category: .quest,
                requirementType: .questCount10,
                requirementValue: 10,
                family: familyRef,
                id: CKRecord.ID(recordName: "ach_quest10", zoneID: zoneID)
            ),
            Achievement(
                name: "Quest Regular",
                description: "Complete 25 quests",
                iconSystemName: "25.circle.fill",
                category: .quest,
                requirementType: .questCount25,
                requirementValue: 25,
                family: familyRef,
                id: CKRecord.ID(recordName: "ach_quest25", zoneID: zoneID)
            ),
            Achievement(
                name: "Quest Champion",
                description: "Complete 50 quests",
                iconSystemName: "50.circle.fill",
                category: .quest,
                requirementType: .questCount50,
                requirementValue: 50,
                family: familyRef,
                id: CKRecord.ID(recordName: "ach_quest50", zoneID: zoneID)
            ),
            Achievement(
                name: "Century Mark",
                description: "Complete 100 quests",
                iconSystemName: "100.circle.fill",
                category: .quest,
                requirementType: .questCount100,
                requirementValue: 100,
                family: familyRef,
                id: CKRecord.ID(recordName: "ach_quest100", zoneID: zoneID)
            )
        ]
    }

    private static func weeklyAndStreakAchievements() -> [Achievement] {
        [
            Achievement(
                name: "Perfect Week",
                description: "Complete all quests in a single week",
                iconSystemName: "checkmark.circle.fill",
                category: .quest,
                requirementType: .weekly100,
                requirementValue: 100,
                family: familyRef,
                id: CKRecord.ID(recordName: "ach_weekly100", zoneID: zoneID)
            ),
            Achievement(
                name: "7-Day Streak",
                description: "Maintain a 7-day quest streak",
                iconSystemName: "flame.fill",
                category: .streak,
                requirementType: .streak7,
                requirementValue: 7,
                family: familyRef,
                id: CKRecord.ID(recordName: "ach_streak7", zoneID: zoneID)
            ),
            Achievement(
                name: "30-Day Streak",
                description: "Maintain a 30-day quest streak",
                iconSystemName: "flame.circle.fill",
                category: .streak,
                requirementType: .streak30,
                requirementValue: 30,
                family: familyRef,
                id: CKRecord.ID(recordName: "ach_streak30", zoneID: zoneID)
            )
        ]
    }

    private static func goalAchievements() -> [Achievement] {
        [
            Achievement(
                name: "First Goal Created",
                description: "Create your first savings goal",
                iconSystemName: "target",
                category: .goal,
                requirementType: .firstGoalCreated,
                requirementValue: 1,
                family: familyRef,
                id: CKRecord.ID(recordName: "ach_goal_created", zoneID: zoneID)
            ),
            Achievement(
                name: "Goal Getter",
                description: "Complete your first savings goal",
                iconSystemName: "flag.checkered",
                category: .goal,
                requirementType: .goalGetter,
                requirementValue: 1,
                family: familyRef,
                id: CKRecord.ID(recordName: "ach_goal_reached", zoneID: zoneID)
            )
        ]
    }

    private static func specialAchievements() -> [Achievement] {
        [
            Achievement(
                name: "Ledger Keeper",
                description: "Log 10 spending entries",
                iconSystemName: "book.pages.fill",
                category: .special,
                requirementType: .ledgerCount10,
                requirementValue: 10,
                family: familyRef,
                id: CKRecord.ID(recordName: "ach_ledger10", zoneID: zoneID)
            ),
            Achievement(
                name: "Early Bird",
                description: "Complete a quest before 9 AM",
                iconSystemName: "sunrise.fill",
                category: .special,
                requirementType: .earlyBird9am,
                requirementValue: 1,
                family: familyRef,
                id: CKRecord.ID(recordName: "ach_earlybird", zoneID: zoneID)
            )
        ]
    }

    // MARK: - Populate

    static func populate(cacheService: CacheService? = nil, boardClaims: Int = 0) {
        let questData = createTemplatesAndQuests(boardClaims: boardClaims)
        let ledger = createLedgerEntries()
        let periods = createAllowancePeriods()
        let (achs, profileAchs) = createAchievements()

        guard let cache = cacheService else { return }
        cache.upsertFamily(family)
        cache.upsertProfiles([heroProfile, secondHeroProfile, parentProfile])
        cache.upsertQuestTemplates(questData.templates)
        cache.upsertQuests(questData.quests)
        cache.upsertQuestCompletions(questData.completions)
        cache.upsertGoals(questData.goals)
        if !ledger.isEmpty {
            cache.upsertLedgerEntries(ledger)
        }
        if !periods.isEmpty {
            cache.upsertAllowancePeriods(periods)
        }
        cache.upsertAchievements(achs)
        cache.upsertProfileAchievements(profileAchs)
    }
}
