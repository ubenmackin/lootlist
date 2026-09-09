//
//  AchievementService+Defaults.swift
//  LootList
//
//  Created by Ben Mackin on 9/9/26.
//

import CloudKit
import Foundation

extension AchievementService {
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
}
