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

    static let familyID = CKRecord.ID(recordName: "fam_dragons", zoneID: zoneID)
    static let familyRef = CKRecord.Reference(recordID: familyID, action: .none)

    static let parentUserID = CKRecord.ID(recordName: "user_arthur", zoneID: zoneID)
    static let hero1UserID = CKRecord.ID(recordName: "user_testalot", zoneID: zoneID)
    static let hero2UserID = CKRecord.ID(recordName: "user_clara", zoneID: zoneID)

    static let hero1ID = CKRecord.ID(recordName: "hero_testalot", zoneID: zoneID)
    static let hero1Ref = CKRecord.Reference(recordID: hero1ID, action: .none)

    static let hero2ID = CKRecord.ID(recordName: "hero_clara", zoneID: zoneID)
    static let hero2Ref = CKRecord.Reference(recordID: hero2ID, action: .none)

    static let parentID = CKRecord.ID(recordName: "parent_arthur", zoneID: zoneID)
    static let parentRef = CKRecord.Reference(recordID: parentID, action: .none)

    static func startOfWeek(for date: Date) -> Date {
        let calendar = Calendar.iso8601UTC
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: components) ?? date
    }

    // MARK: - Family & Profiles

    static var family: Family {
        Family(
            name: "Dragons of Eldoria",
            createdBy: parentUserID,
            payoutPolicy: .perQuest,
            id: familyID
        )
    }

    static var heroProfile: Profile {
        var profile = Profile(
            displayName: "Sir Testalot",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .hero,
            iCloudUserID: hero1UserID,
            family: familyRef,
            id: hero1ID
        )
        profile.xp = 4250
        profile.level = 8
        return profile
    }

    static var secondHeroProfile: Profile {
        var profile = Profile(
            displayName: "Lady Clara",
            avatarClass: .rogue,
            avatarPresetID: "rogue_03",
            role: .hero,
            iCloudUserID: hero2UserID,
            family: familyRef,
            id: hero2ID
        )
        profile.xp = 1850
        profile.level = 4
        return profile
    }

    static var parentProfile: Profile {
        Profile(
            displayName: "Guild Master Arthur",
            avatarClass: .guardian,
            avatarPresetID: "guardian_01",
            role: .guildMaster,
            iCloudUserID: parentUserID,
            family: familyRef,
            id: parentID
        )
    }

    // MARK: - Templates & Quests

    struct SampleQuestData {
        let templates: [QuestTemplate]
        let quests: [Quest]
        let completions: [QuestCompletion]
    }

    private struct TemplateSeed {
        let name: String
        let desc: String
        let gold: Double
        let xp: Int
        let sched: QuestSchedule
        let approval: ApprovalMode
    }

    static func createTemplatesAndQuests() -> SampleQuestData {
        let currentWeek = startOfWeek(for: Date())

        let templatesData: [TemplateSeed] = [
            TemplateSeed(
                name: "Complete the Homework Beast",
                desc: "30 minutes of math and spellcraft reading",
                gold: 7.50,
                xp: 75,
                sched: .weeklyFlexible,
                approval: .autoApprove
            ),
            TemplateSeed(name: "Clean the Dragon's Lair", desc: "Tidy bedroom floor and organize chest", gold: 5.00, xp: 50, sched: .weeklyFlexible, approval: .autoApprove),
            TemplateSeed(name: "Empty the Treasure Chest", desc: "Take out recycling and trash", gold: 3.50, xp: 35, sched: .weeklyFlexible, approval: .autoApprove),
            TemplateSeed(name: "Polishing the Armor", desc: "Fold and put away clean laundry", gold: 6.00, xp: 60, sched: .weeklyFlexible, approval: .parentVerify),
            TemplateSeed(name: "Feed the Royal Hound", desc: "Feed and give fresh water to pet", gold: 3.00, xp: 30, sched: .weeklyFlexible, approval: .autoApprove),
            TemplateSeed(name: "Clear the Feast Table", desc: "Load and unload the dishwasher", gold: 4.50, xp: 45, sched: .weeklyFlexible, approval: .autoApprove),
            TemplateSeed(name: "Water the Elven Gardens", desc: "Water household and patio plants", gold: 4.00, xp: 40, sched: .specificDays, approval: .autoApprove),
            TemplateSeed(name: "Organize the Armory", desc: "Tidy entryway shoes, coats, and backpacks", gold: 5.00, xp: 50, sched: .weeklyFlexible, approval: .autoApprove),
            TemplateSeed(name: "Wash the Guild Carriage", desc: "Help wash and vacuum family vehicle", gold: 12.50, xp: 125, sched: .weeklyFlexible, approval: .parentVerify),
            TemplateSeed(name: "Make the Royal Bed", desc: "Make bed neatly before morning questing", gold: 2.50, xp: 25, sched: .weeklyFlexible, approval: .autoApprove),
            TemplateSeed(name: "Sort the Supply Crate", desc: "Unpack and organize weekly groceries", gold: 5.00, xp: 50, sched: .weeklyFlexible, approval: .parentVerify),
            TemplateSeed(name: "Read the Ancient Grimoire", desc: "Read 1 chapter of an adventure book", gold: 8.00, xp: 80, sched: .weeklyFlexible, approval: .autoApprove)
        ]

        var templates: [QuestTemplate] = []
        var quests: [Quest] = []
        var completions: [QuestCompletion] = []

        for (index, item) in templatesData.enumerated() {
            let tID = CKRecord.ID(recordName: "template_\(index + 1)", zoneID: zoneID)
            let templateRef = CKRecord.Reference(recordID: tID, action: .none)

            let template = QuestTemplate(
                name: item.name,
                description: item.desc,
                defaultGold: item.gold,
                xpReward: item.xp,
                scheduleType: item.sched,
                specificDays: item.sched == .specificDays ? ["monday", "wednesday", "friday"] : [],
                isAllOrNothing: false,
                approvalMode: item.approval,
                createdBy: parentRef,
                family: familyRef,
                id: tID
            )
            templates.append(template)

            let qID = CKRecord.ID(recordName: "quest_hero1_\(index + 1)", zoneID: zoneID)
            let questRef = CKRecord.Reference(recordID: qID, action: .none)

            let quest = Quest(
                template: templateRef,
                assignee: hero1Ref,
                goldReward: item.gold,
                xpReward: item.xp,
                scheduleType: item.sched,
                isAllOrNothing: false,
                approvalMode: item.approval,
                weekOf: currentWeek,
                createdBy: parentRef,
                family: familyRef,
                name: item.name,
                descriptionText: item.desc,
                id: qID
            )
            quests.append(quest)

            if index < 5 {
                let cID = CKRecord.ID(recordName: "completion_\(index + 1)", zoneID: zoneID)
                let comp = QuestCompletion(
                    quest: questRef,
                    completedBy: hero1Ref,
                    approvalMode: .autoApprove,
                    weekOf: currentWeek,
                    family: familyRef,
                    id: cID
                )
                completions.append(comp)
            } else if item.approval == .parentVerify {
                let cID = CKRecord.ID(recordName: "completion_\(index + 1)", zoneID: zoneID)
                let comp = QuestCompletion(
                    quest: questRef,
                    completedBy: hero1Ref,
                    approvalMode: .parentVerify,
                    weekOf: currentWeek,
                    family: familyRef,
                    id: cID
                )
                completions.append(comp)
            }
        }

        return SampleQuestData(
            templates: templates,
            quests: quests,
            completions: completions
        )
    }

    // MARK: - Ledger Entries

    static func createLedgerEntries() -> [LedgerEntry] {
        [
            LedgerEntry(
                profile: hero1Ref,
                amount: -15.00,
                description: "Wooden Training Sword & Shield",
                date: Date().addingTimeInterval(-86400 * 2),
                source: "manual",
                family: familyRef,
                id: CKRecord.ID(recordName: "ledger_1", zoneID: zoneID)
            ),
            LedgerEntry(
                profile: hero1Ref,
                amount: 10.00,
                description: "Loot Drop: 10-Day Combo Streak Bonus! 🔥",
                date: Date().addingTimeInterval(-86400 * 3),
                source: "bonus",
                family: familyRef,
                id: CKRecord.ID(recordName: "ledger_2", zoneID: zoneID)
            ),
            LedgerEntry(
                profile: hero1Ref,
                amount: -4.50,
                description: "Frost Elixir (Ice Cream treat)",
                date: Date().addingTimeInterval(-86400 * 4),
                source: "manual",
                family: familyRef,
                id: CKRecord.ID(recordName: "ledger_3", zoneID: zoneID)
            ),
            LedgerEntry(
                profile: hero1Ref,
                amount: 5.00,
                description: "Loot Drop: 10 Quests Completed Milestone! ⚔️",
                date: Date().addingTimeInterval(-86400 * 5),
                source: "bonus",
                family: familyRef,
                id: CKRecord.ID(recordName: "ledger_4", zoneID: zoneID)
            ),
            LedgerEntry(
                profile: hero1Ref,
                amount: -12.00,
                description: "Board Game Expansion Pack",
                date: Date().addingTimeInterval(-86400 * 6),
                source: "manual",
                family: familyRef,
                id: CKRecord.ID(recordName: "ledger_5", zoneID: zoneID)
            )
        ]
    }

    // MARK: - Allowance Periods

    static func createAllowancePeriods() -> [AllowancePeriod] {
        let calendar = Calendar.iso8601UTC
        let currentWeek = startOfWeek(for: Date())

        let week1 = calendar.date(byAdding: .day, value: -7, to: currentWeek) ?? currentWeek.addingTimeInterval(-86400 * 7)
        let week2 = calendar.date(byAdding: .day, value: -14, to: currentWeek) ?? currentWeek.addingTimeInterval(-86400 * 14)
        let week3 = calendar.date(byAdding: .day, value: -21, to: currentWeek) ?? currentWeek.addingTimeInterval(-86400 * 21)

        var p0 = AllowancePeriod(
            weekOf: currentWeek,
            profile: hero1Ref,
            questsTotal: 12,
            family: familyRef,
            id: CKRecord.ID(recordName: "period_0", zoneID: zoneID)
        )
        p0.status = .active
        p0.totalEarned = 38.50
        p0.questsCompleted = 7

        var p1 = AllowancePeriod(
            weekOf: week1,
            profile: hero1Ref,
            questsTotal: 10,
            family: familyRef,
            id: CKRecord.ID(recordName: "period_1", zoneID: zoneID)
        )
        p1.status = .paid
        p1.totalEarned = 45.00
        p1.questsCompleted = 10
        p1.paidDate = week1.addingTimeInterval(86400 * 6)
        p1.paidAmount = 45.00

        var p2 = AllowancePeriod(
            weekOf: week2,
            profile: hero1Ref,
            questsTotal: 10,
            family: familyRef,
            id: CKRecord.ID(recordName: "period_2", zoneID: zoneID)
        )
        p2.status = .paid
        p2.totalEarned = 36.50
        p2.questsCompleted = 9
        p2.paidDate = week2.addingTimeInterval(86400 * 6)
        p2.paidAmount = 36.50

        var p3 = AllowancePeriod(
            weekOf: week3,
            profile: hero1Ref,
            questsTotal: 10,
            family: familyRef,
            id: CKRecord.ID(recordName: "period_3", zoneID: zoneID)
        )
        p3.status = .paid
        p3.totalEarned = 40.00
        p3.questsCompleted = 10
        p3.paidDate = week3.addingTimeInterval(86400 * 6)
        p3.paidAmount = 40.00

        return [p0, p1, p2, p3]
    }

    // MARK: - Achievements

    static func createAchievements() -> ([Achievement], [ProfileAchievement]) {
        let defaultAchs = [
            Achievement(
                name: "First Steps",
                description: "Complete your first quest",
                iconSystemName: "shoeprints.fill",
                category: .quest,
                requirementType: .firstQuest,
                requirementValue: 1,
                family: familyRef,
                id: CKRecord.ID(recordName: "ach_1", zoneID: zoneID)
            ),
            Achievement(
                name: "Questing Squire",
                description: "Complete 10 quests",
                iconSystemName: "flag.checkered",
                category: .quest,
                requirementType: .questCount10,
                requirementValue: 10,
                family: familyRef,
                id: CKRecord.ID(recordName: "ach_2", zoneID: zoneID)
            ),
            Achievement(
                name: "7-Day Flame",
                description: "Maintain a 7-day quest streak",
                iconSystemName: "flame.fill",
                category: .streak,
                requirementType: .streak7,
                requirementValue: 7,
                family: familyRef,
                id: CKRecord.ID(recordName: "ach_3", zoneID: zoneID)
            ),
            Achievement(
                name: "Treasure Hoarder",
                description: "Earn \(CurrencyFormatter.string(100)) lifetime",
                iconSystemName: "banknote",
                category: .gold,
                requirementType: .gold100,
                requirementValue: 100,
                family: familyRef,
                id: CKRecord.ID(recordName: "ach_4", zoneID: zoneID)
            ),
            Achievement(
                name: "Quest Knight",
                description: "Complete 50 quests",
                iconSystemName: "figure.fencing",
                category: .quest,
                requirementType: .questCount50,
                requirementValue: 50,
                family: familyRef,
                id: CKRecord.ID(recordName: "ach_5", zoneID: zoneID)
            )
        ]

        let profileAchs = [
            ProfileAchievement(
                achievement: CKRecord.Reference(recordID: CKRecord.ID(recordName: "ach_1", zoneID: zoneID), action: .none),
                profile: hero1Ref,
                earnedDate: Date().addingTimeInterval(-86400 * 20),
                family: familyRef,
                id: CKRecord.ID(recordName: "pach_1", zoneID: zoneID)
            ),
            ProfileAchievement(
                achievement: CKRecord.Reference(recordID: CKRecord.ID(recordName: "ach_2", zoneID: zoneID), action: .none),
                profile: hero1Ref,
                earnedDate: Date().addingTimeInterval(-86400 * 10),
                family: familyRef,
                id: CKRecord.ID(recordName: "pach_2", zoneID: zoneID)
            ),
            ProfileAchievement(
                achievement: CKRecord.Reference(recordID: CKRecord.ID(recordName: "ach_3", zoneID: zoneID), action: .none),
                profile: hero1Ref,
                earnedDate: Date().addingTimeInterval(-86400 * 5),
                family: familyRef,
                id: CKRecord.ID(recordName: "pach_3", zoneID: zoneID)
            )
        ]

        return (defaultAchs, profileAchs)
    }

    static func populate(cloudKit: CloudKitService, cacheService: CacheService? = nil) {
        let questData = createTemplatesAndQuests()
        let ledger = createLedgerEntries()
        let periods = createAllowancePeriods()
        let (achs, profileAchs) = createAchievements()

        var allRecords: [any CloudKitRecord] = []
        allRecords.append(family)
        allRecords.append(heroProfile)
        allRecords.append(secondHeroProfile)
        allRecords.append(parentProfile)
        allRecords.append(contentsOf: questData.templates)
        allRecords.append(contentsOf: questData.quests)
        allRecords.append(contentsOf: questData.completions)
        allRecords.append(contentsOf: ledger)
        allRecords.append(contentsOf: periods)
        allRecords.append(contentsOf: achs)
        allRecords.append(contentsOf: profileAchs)

        cloudKit.seedMockRecords(allRecords)

        if let cache = cacheService {
            cache.upsertFamily(family)
            cache.upsertProfiles([heroProfile, secondHeroProfile, parentProfile])
            cache.upsertQuestTemplates(questData.templates)
            cache.upsertQuests(questData.quests)
            cache.upsertQuestCompletions(questData.completions)
            cache.upsertLedgerEntries(ledger)
            cache.upsertAllowancePeriods(periods)
            cache.upsertAchievements(achs)
            cache.upsertProfileAchievements(profileAchs)
        }
    }
}
