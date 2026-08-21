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

    // MARK: - Templates & Quests (minimal 3-item fixture)

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
                name: item.name,
                description: item.desc,
                defaultGold: item.gold,
                xpReward: item.xp,
                scheduleType: item.sched,
                specificDays: [],
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

            if index < 2 {
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

    // MARK: - Ledger Entries (pruned — empty for previews; real data comes from user actions)

    static func createLedgerEntries() -> [LedgerEntry] {
        []
    }

    // MARK: - Allowance Periods (pruned — seeded on demand via DataMigrationsCoordinator)

    static func createAllowancePeriods() -> [AllowancePeriod] {
        []
    }

    // MARK: - Achievements (minimal)

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
            )
        ]

        let profileAchs = [
            ProfileAchievement(
                achievement: CKRecord.Reference(recordID: CKRecord.ID(recordName: "ach_1", zoneID: zoneID), action: .none),
                profile: hero1Ref,
                earnedDate: Date().addingTimeInterval(-86400 * 5),
                family: familyRef,
                id: CKRecord.ID(recordName: "pach_1", zoneID: zoneID)
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
}
