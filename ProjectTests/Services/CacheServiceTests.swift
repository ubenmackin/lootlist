//
//  CacheServiceTests.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
@testable import LootList
import SwiftData
import Testing

@MainActor
struct CacheServiceTests {
    // MARK: - Helpers

    private func makeService() throws -> CacheService {
        try CacheService(inMemory: true)
    }

    private func ref(_ name: String) -> CKRecord.Reference {
        CKRecord.Reference(recordID: CKRecord.ID(recordName: name), action: .none)
    }

    // MARK: - Quest Upserts

    @Test
    func `upsert quest inserts new record`() throws {
        let service = try makeService()
        let quest = Quest(
            template: ref("tpl"),
            assignee: ref("hero"),
            goldReward: 5.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            approvalMode: .autoApprove,
            weekOf: Date(),
            createdBy: ref("user1"),
            family: ref("fam"),
            name: "Clean Room",
            id: CKRecord.ID(recordName: "quest1")
        )

        service.upsertQuest(quest)

        let quests = service.fetchQuests(family: "fam")
        #expect(quests.count == 1)
        #expect(quests.first?.recordName == "quest1")
        #expect(quests.first?.questName == "Clean Room")
    }

    @Test
    func `upsert quest updates existing record`() throws {
        let service = try makeService()
        let quest = Quest(
            template: ref("tpl"),
            assignee: ref("hero"),
            goldReward: 5.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            approvalMode: .autoApprove,
            weekOf: Date(),
            createdBy: ref("user1"),
            family: ref("fam"),
            name: "Clean Room",
            id: CKRecord.ID(recordName: "quest1")
        )
        service.upsertQuest(quest)

        var updated = quest
        updated.goldReward = 10.0
        updated.name = "Mega Clean Room"
        service.upsertQuest(updated)

        let quests = service.fetchQuests(family: "fam")
        #expect(quests.count == 1)
        #expect(quests.first?.goldReward == 10.0)
        #expect(quests.first?.questName == "Mega Clean Room")
    }

    @Test
    func `upsert quest preserves change tag when nil`() throws {
        // Signal-2 regression guard: when the incoming changeTag is nil,
        // the existing server-side tag must NOT be overwritten.
        let service = try makeService()
        var quest = Quest(
            template: ref("tpl"),
            assignee: ref("hero"),
            goldReward: 5.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            approvalMode: .autoApprove,
            weekOf: Date(),
            createdBy: ref("user1"),
            family: ref("fam"),
            name: "Clean Room",
            id: CKRecord.ID(recordName: "quest1")
        )
        quest.changeTag = "server-v1"
        service.upsertQuest(quest)

        // Upsert same record with nil changeTag — existing tag must survive.
        var upserted = quest
        upserted.changeTag = nil
        service.upsertQuest(upserted)

        let quests = service.fetchQuests(family: "fam")
        #expect(quests.count == 1)
        #expect(quests.first?.changeTag == "server-v1")
    }

    @Test
    func `upsert quest overwrites change tag when non nil`() throws {
        let service = try makeService()
        var quest = Quest(
            template: ref("tpl"),
            assignee: ref("hero"),
            goldReward: 5.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            approvalMode: .autoApprove,
            weekOf: Date(),
            createdBy: ref("user1"),
            family: ref("fam"),
            name: "Clean Room",
            id: CKRecord.ID(recordName: "quest1")
        )
        quest.changeTag = "server-v1"
        service.upsertQuest(quest)

        // Upsert with a new changeTag — must overwrite the existing value.
        var upserted = quest
        upserted.changeTag = "server-v2"
        service.upsertQuest(upserted)

        let quests = service.fetchQuests(family: "fam")
        #expect(quests.count == 1)
        #expect(quests.first?.changeTag == "server-v2")
    }

    // MARK: - Invalidation & Fetch

    @Test
    func `invalidate quest removes record`() throws {
        let service = try makeService()
        let quest = Quest(
            template: ref("tpl"),
            assignee: ref("hero"),
            goldReward: 5.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            approvalMode: .autoApprove,
            weekOf: Date(),
            createdBy: ref("user1"),
            family: ref("fam"),
            name: "Clean Room",
            id: CKRecord.ID(recordName: "quest1")
        )
        service.upsertQuest(quest)
        #expect(service.fetchQuests(family: "fam").count == 1)

        service.invalidateQuest(recordName: "quest1")

        #expect(service.fetchQuests(family: "fam").count == 0)
    }

    @Test
    func `fetch quest returns nil for missing record`() throws {
        let service = try makeService()

        // No quests inserted — fetch for a nonexistent family returns empty.
        let quests = service.fetchQuests(family: "nonexistent")
        #expect(quests.isEmpty)
    }

    @Test
    func `fetch quests filters by family`() throws {
        let service = try makeService()
        let questA = Quest(
            template: ref("tpl"),
            assignee: ref("hero"),
            goldReward: 5.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            approvalMode: .autoApprove,
            weekOf: Date(),
            createdBy: ref("user1"),
            family: ref("famA"),
            name: "Quest A",
            id: CKRecord.ID(recordName: "questA")
        )
        let questB = Quest(
            template: ref("tpl"),
            assignee: ref("hero"),
            goldReward: 5.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            approvalMode: .autoApprove,
            weekOf: Date(),
            createdBy: ref("user1"),
            family: ref("famB"),
            name: "Quest B",
            id: CKRecord.ID(recordName: "questB")
        )
        service.upsertQuest(questA)
        service.upsertQuest(questB)

        let famAQuests = service.fetchQuests(family: "famA")
        #expect(famAQuests.count == 1)
        #expect(famAQuests.first?.recordName == "questA")

        let famBQuests = service.fetchQuests(family: "famB")
        #expect(famBQuests.count == 1)
        #expect(famBQuests.first?.recordName == "questB")
    }

    // MARK: - Bulk Clear

    @Test
    func `clear all removes all records`() throws {
        let service = try makeService()
        let quest = Quest(
            template: ref("tpl"),
            assignee: ref("hero"),
            goldReward: 5.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            approvalMode: .autoApprove,
            weekOf: Date(),
            createdBy: ref("user1"),
            family: ref("fam"),
            name: "Q",
            id: CKRecord.ID(recordName: "q1")
        )
        let family = Family(
            name: "Dragons",
            createdBy: CKRecord.ID(recordName: "user1"),
            id: CKRecord.ID(recordName: "fam")
        )
        service.upsertQuest(quest)
        service.upsertFamily(family)
        #expect(service.fetchQuests(family: "fam").count == 1)

        service.clearAll()

        #expect(service.fetchQuests(family: "fam").count == 0)
        #expect(service.fetchFamily(recordName: "fam") == nil)
    }

    // MARK: - Notification Preference ChangeTag

    @Test
    func `upsert notification preference preserves change tag`() throws {
        let service = try makeService()
        var pref = NotificationPreference(
            profile: ref("hero"),
            eventType: .questCompleted,
            enabled: true,
            pushEnabled: true,
            family: ref("fam"),
            id: CKRecord.ID(recordName: "pref1")
        )
        pref.changeTag = "server-v1"
        service.upsertNotificationPreference(pref)

        // Upsert with nil changeTag — existing tag must be preserved.
        var upserted = pref
        upserted.changeTag = nil
        service.upsertNotificationPreference(upserted)

        let prefs = service.fetchNotificationPreferences(profileRecordName: "hero")
        #expect(prefs.count == 1)
        #expect(prefs.first?.changeTag == "server-v1")
    }

    // MARK: - Per-Family Purge (M4 Regression)

    @Test
    func `purge family removes only target family rows`() throws {
        let service = try makeService()

        // Seed two families with their own quests.
        let familyA = Family(
            name: "Dragons",
            createdBy: CKRecord.ID(recordName: "user1"),
            id: CKRecord.ID(recordName: "famA")
        )
        let familyB = Family(
            name: "Unicorns",
            createdBy: CKRecord.ID(recordName: "user2"),
            id: CKRecord.ID(recordName: "famB")
        )
        service.upsertFamily(familyA)
        service.upsertFamily(familyB)

        let questA = Quest(
            template: ref("tpl"),
            assignee: ref("hero"),
            goldReward: 5.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            approvalMode: .autoApprove,
            weekOf: Date(),
            createdBy: ref("user1"),
            family: ref("famA"),
            name: "Quest A",
            id: CKRecord.ID(recordName: "questA")
        )
        let questB = Quest(
            template: ref("tpl"),
            assignee: ref("hero"),
            goldReward: 5.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            approvalMode: .autoApprove,
            weekOf: Date(),
            createdBy: ref("user2"),
            family: ref("famB"),
            name: "Quest B",
            id: CKRecord.ID(recordName: "questB")
        )
        service.upsertQuest(questA)
        service.upsertQuest(questB)
        #expect(service.fetchQuests(family: "famA").count == 1)
        #expect(service.fetchQuests(family: "famB").count == 1)

        // Purge only famA.
        service.purgeFamily(recordName: "famA")

        // famA must be fully removed.
        #expect(service.fetchFamily(recordName: "famA") == nil)
        #expect(service.fetchQuests(family: "famA").count == 0)

        // famB must be untouched.
        #expect(service.fetchFamily(recordName: "famB") != nil)
        #expect(service.fetchQuests(family: "famB").count == 1)
    }

    // MARK: - Remaining Entity Upserts

    @Test
    func `upsert profile inserts new record`() throws {
        let service = try makeService()
        let profile = Profile(
            displayName: "Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "icloud1"),
            family: ref("fam"),
            id: CKRecord.ID(recordName: "profile1")
        )

        service.upsertProfile(profile)

        let profiles = service.fetchProfiles(family: "fam")
        #expect(profiles.count == 1)
        #expect(profiles.first?.displayName == "Hero")
    }

    @Test
    func `upsert quest template inserts new record`() throws {
        let service = try makeService()
        let template = QuestTemplate(
            name: "Clean Room",
            description: "Tidy up",
            defaultGold: 5.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            approvalMode: .autoApprove,
            createdBy: ref("user1"),
            family: ref("fam"),
            id: CKRecord.ID(recordName: "tpl1")
        )

        service.upsertQuestTemplate(template)

        let templates = service.fetchQuestTemplates(family: "fam")
        #expect(templates.count == 1)
        #expect(templates.first?.name == "Clean Room")
    }

    @Test
    func `upsert quest completion inserts new record`() throws {
        let service = try makeService()
        let completion = QuestCompletion(
            quest: ref("quest1"),
            completedBy: ref("hero"),
            approvalMode: .parentVerify,
            completedDate: Date(),
            weekOf: Date(),
            family: ref("fam"),
            id: CKRecord.ID(recordName: "comp1")
        )

        service.upsertQuestCompletion(completion)

        let completions = service.fetchQuestCompletions(family: "fam")
        #expect(completions.count == 1)
        #expect(completions.first?.recordName == "comp1")
    }

    @Test
    func `upsert ledger entry inserts new record`() throws {
        let service = try makeService()
        let entry = LedgerEntry(
            profile: ref("hero"),
            amount: 5.0,
            description: "Bonus",
            family: ref("fam"),
            id: CKRecord.ID(recordName: "entry1")
        )

        service.upsertLedgerEntry(entry)

        let entries = service.fetchLedgerEntries(profileRecordName: "hero")
        #expect(entries.count == 1)
        #expect(entries.first?.amount == 5.0)
    }

    @Test
    func `upsert allowance period inserts new record`() throws {
        let service = try makeService()
        let period = AllowancePeriod(
            weekOf: Date(),
            profile: ref("hero"),
            questsTotal: 5,
            family: ref("fam"),
            id: CKRecord.ID(recordName: "period1")
        )

        service.upsertAllowancePeriod(period)

        let periods = service.fetchAllowancePeriods(profileRecordName: "hero")
        #expect(periods.count == 1)
        #expect(periods.first?.questsTotal == 5)
    }

    @Test
    func `upsert achievement inserts new record`() throws {
        let service = try makeService()
        let achievement = Achievement(
            name: "First Quest",
            description: "Complete your first quest",
            iconSystemName: "star.fill",
            category: .quest,
            requirementType: .firstQuest,
            requirementValue: 1,
            family: ref("fam"),
            id: CKRecord.ID(recordName: "ach1")
        )

        service.upsertAchievement(achievement)

        let achievements = service.fetchAchievements(family: "fam")
        #expect(achievements.count == 1)
        #expect(achievements.first?.name == "First Quest")
    }

    @Test
    func `upsert profile achievement inserts new record`() throws {
        let service = try makeService()
        let pa = ProfileAchievement(
            achievement: ref("ach1"),
            profile: ref("hero"),
            family: ref("fam"),
            id: CKRecord.ID(recordName: "pa1")
        )

        service.upsertProfileAchievement(pa)

        let pas = service.fetchProfileAchievements(profileRecordName: "hero")
        #expect(pas.count == 1)
        #expect(pas.first?.recordName == "pa1")
    }

    @Test
    func `upsert family inserts new record`() throws {
        let service = try makeService()
        let family = Family(
            name: "Dragons",
            createdBy: CKRecord.ID(recordName: "user1"),
            id: CKRecord.ID(recordName: "fam1")
        )

        service.upsertFamily(family)

        let cached = service.fetchFamily(recordName: "fam1")
        #expect(cached != nil)
        #expect(cached?.name == "Dragons")
    }
}
