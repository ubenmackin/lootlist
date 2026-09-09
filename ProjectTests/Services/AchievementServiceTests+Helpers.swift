//
//  AchievementServiceTests+Helpers.swift
//  LootList
//
//  Created by Ben Mackin on 9/9/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

private struct QuestTrophySpec {
    let requirement: AchievementRequirement
    let name: String
    let value: Int
}

@MainActor
extension AchievementServiceTests {
    func makeGoal(_ zoneID: CKRecordZone.ID, hero: Profile, familyRef: CKRecord.Reference, name: String = "Bike", completed: Bool = false) -> Goal {
        Goal(
            profile: CKRecord.Reference(recordID: hero.id, action: .none),
            family: familyRef,
            bucketKind: .shortTermSave,
            name: name,
            targetAmountPennies: 5000,
            createdAt: Date(),
            completedAt: completed ? Date() : nil,
            id: CKRecord.ID(recordName: "goal-\(UUID().uuidString)", zoneID: zoneID)
        )
    }

    func makeQuestCompletion(_ zoneID: CKRecordZone.ID, hero: Profile, familyRef: CKRecord.Reference, weekOf: Date, questName: String = "q",
                             id: String) -> QuestCompletion
    {
        QuestCompletion(
            quest: CKRecord.Reference(recordID: CKRecord.ID(recordName: questName, zoneID: zoneID), action: .none),
            completedBy: CKRecord.Reference(recordID: hero.id, action: .none),
            approvalMode: .autoApprove,
            completedDate: Date(),
            weekOf: weekOf,
            family: familyRef,
            id: CKRecord.ID(recordName: id, zoneID: zoneID)
        )
    }

    func seedQuestCountAchievements(in cache: CacheService, zoneID: CKRecordZone.ID, familyRef: CKRecord.Reference) {
        let defs: [QuestTrophySpec] = [
            QuestTrophySpec(requirement: .firstQuest, name: "First Steps", value: 1),
            QuestTrophySpec(requirement: .questCount10, name: "Questing Squire", value: 10),
            QuestTrophySpec(requirement: .questCount25, name: "Questing Apprentice", value: 25),
            QuestTrophySpec(requirement: .questCount50, name: "Quest Knight", value: 50),
            QuestTrophySpec(requirement: .questCount100, name: "Quest Legend", value: 100)
        ]
        for spec in defs {
            let achievement = Achievement(
                id: CKRecord.ID(recordName: "fam1-\(spec.requirement.rawValue)", zoneID: zoneID),
                name: spec.name,
                description: "Complete \(spec.value) quests",
                iconSystemName: "trophy.fill",
                category: .quest,
                requirementType: spec.requirement,
                requirementValue: spec.value,
                family: familyRef
            )
            cache.context?.insert(AchievementCache(from: achievement))
        }
        _ = cache.saveContext()
        cache.markCacheFreshForTests(familyRecordName: "fam1", type: .achievement)
        cache.markCacheFreshForTests(familyRecordName: "fam1", type: .profileAchievement)
        cache.markCacheFreshForTests(familyRecordName: "fam1", type: .questCompletion)
        cache.markCacheFreshForTests(familyRecordName: "fam1", type: .quest)
        cache.markCacheFreshForTests(familyRecordName: "fam1", type: .ledgerEntry)
        cache.markCacheFreshForTests(familyRecordName: "fam1", type: .goal)
    }

    func seedCompletions(count: Int, hero: Profile, zoneID: CKRecordZone.ID, familyRef: CKRecord.Reference, cache: CacheService, weekOf: Date) {
        for completionIndex in 0 ..< count {
            let log = QuestCompletion(
                quest: CKRecord.Reference(recordID: CKRecord.ID(recordName: "q-\(completionIndex)", zoneID: zoneID), action: .none),
                completedBy: CKRecord.Reference(recordID: hero.id, action: .none),
                approvalMode: .autoApprove,
                completedDate: Date(),
                weekOf: weekOf,
                family: familyRef,
                id: CKRecord.ID(recordName: "log-\(completionIndex)-\(UUID().uuidString)", zoneID: zoneID)
            )
            // Ensure verificationStatus is autoApproved (default from init is verified/autoApproved).
            var verified = log
            verified.verificationStatus = .autoApproved
            cache.context?.insert(QuestCompletionCache(from: verified))
        }
        _ = cache.saveContext()
    }
}
