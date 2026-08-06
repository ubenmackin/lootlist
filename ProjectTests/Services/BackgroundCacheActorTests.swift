//
//  BackgroundCacheActorTests.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
@testable import LootList
import SwiftData
import Testing

struct BackgroundCacheActorTests {
    // MARK: - Helpers

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(
            for: QuestCache.self,
            QuestTemplateCache.self,
            ProfileCache.self,
            QuestCompletionCache.self,
            FamilyCache.self,
            LedgerEntryCache.self,
            AllowancePeriodCache.self,
            AchievementCache.self,
            ProfileAchievementCache.self,
            NotificationPreferenceCache.self,
            configurations: config
        )
    }

    private func seedAllCaches(_ container: ModelContainer, prefix: String) throws {
        let ctx = ModelContext(container)
        let now = Date()

        ctx.insert(ProfileCache(
            recordName: "\(prefix)profile", familyRecordName: "fam", displayName: "Hero",
            role: "hero", xpTotal: 0, avatarName: nil, isActive: true, level: 1,
            iCloudUserRecordName: "user1", avatarClass: nil, payoutPolicy: "perQuest"
        ))
        ctx.insert(FamilyCache(
            recordName: "\(prefix)family", name: "Dragons", createdByRecordName: "user1",
            createdAt: now, payoutPolicy: "perQuest"
        ))
        ctx.insert(QuestCache(
            recordName: "\(prefix)quest", familyRecordName: "fam", assigneeRecordName: "hero",
            templateRecordName: "tpl", weekOf: now, questName: "Clean Room", isActive: true,
            goldReward: 5, xpReward: 50, rarity: "common", scheduleType: "weeklyFlexible",
            isAllOrNothing: false, approvalMode: "autoApprove", descriptionText: nil,
            createdByRecordName: "user1"
        ))
        ctx.insert(QuestTemplateCache(
            recordName: "\(prefix)questTemplate", familyRecordName: "fam", name: "Clean Room",
            isActive: true, goldReward: 5, xpReward: 50, rarity: "common", specificDays: nil,
            templateDescription: "Tidy up", scheduleType: "weeklyFlexible",
            isAllOrNothing: false, approvalMode: "autoApprove", createdByRecordName: "user1"
        ))
        ctx.insert(QuestCompletionCache(
            recordName: "\(prefix)questCompletion", questRecordName: "quest",
            familyRecordName: "fam", completerRecordName: "hero", completedDate: now,
            weekOf: now, verificationStatus: "pending", approvalMode: "parentVerify",
            verifiedByRecordName: nil, verifiedDate: nil
        ))
        ctx.insert(LedgerEntryCache(
            recordName: "\(prefix)ledgerEntry", profileRecordName: "hero",
            familyRecordName: "fam", amount: 5.0, entryDescription: "Bonus", date: now,
            source: "manual"
        ))
        ctx.insert(AllowancePeriodCache(
            recordName: "\(prefix)allowancePeriod", profileRecordName: "hero",
            familyRecordName: "fam", weekOf: now, status: "pending", totalEarned: 0,
            questsCompleted: 0, questsTotal: 0
        ))
        ctx.insert(AchievementCache(
            recordName: "\(prefix)achievement", familyRecordName: "fam", name: "First Quest",
            achievementDescription: "Complete your first quest", iconSystemName: "star.fill",
            category: "quest", requirementType: "questCount", requirementValue: 1
        ))
        ctx.insert(ProfileAchievementCache(
            recordName: "\(prefix)profileAchievement", achievementRecordName: "achievement",
            profileRecordName: "hero", familyRecordName: "fam", earnedDate: now
        ))
        ctx.insert(NotificationPreferenceCache(
            recordName: "\(prefix)notificationPreference", profileRecordName: "hero",
            familyRecordName: "fam", eventType: "questCompleted", enabled: true,
            pushEnabled: true
        ))

        try ctx.save()
    }

    private func remainingCount<T: PersistentModel>(_: T.Type, in container: ModelContainer) throws -> Int {
        let ctx = ModelContext(container)
        return try ctx.fetch(FetchDescriptor<T>()).count
    }

    // MARK: - Tests

    @Test
    func `resolver maps each CloudKit recordType to the typed case`() {
        // The divergence that motivated this change: QuestCompletion's
        // CKRecordType is "QuestLog", not "QuestCompletion".
        #expect(QuestCompletion.recordType == "QuestLog")
        #expect(CachedRecordType.recordType(for: QuestCompletion.recordType) == .questCompletion)
        #expect(CachedRecordType.recordType(for: "QuestCompletion") == nil)

        #expect(CachedRecordType.recordType(for: Profile.recordType) == .profile)
        #expect(CachedRecordType.recordType(for: Family.recordType) == .family)
        #expect(CachedRecordType.recordType(for: Quest.recordType) == .quest)
        #expect(CachedRecordType.recordType(for: QuestTemplate.recordType) == .questTemplate)
        #expect(CachedRecordType.recordType(for: LedgerEntry.recordType) == .ledgerEntry)
        #expect(CachedRecordType.recordType(for: AllowancePeriod.recordType) == .allowancePeriod)
        #expect(CachedRecordType.recordType(for: Achievement.recordType) == .achievement)
        #expect(CachedRecordType.recordType(for: ProfileAchievement.recordType) == .profileAchievement)
        #expect(CachedRecordType.recordType(for: NotificationPreference.recordType) == .notificationPreference)
    }

    @Test
    func `deleting QuestLog recordType removes QuestCompletionCache row`() async throws {
        let container = try makeContainer()
        let recordName = "qc_divergence"
        let ctx = ModelContext(container)
        let now = Date()
        ctx.insert(QuestCompletionCache(
            recordName: recordName, questRecordName: "q", familyRecordName: "fam",
            completerRecordName: "hero", completedDate: now, weekOf: now,
            verificationStatus: "pending", approvalMode: "parentVerify",
            verifiedByRecordName: nil, verifiedDate: nil
        ))
        try ctx.save()

        #expect(try remainingCount(QuestCompletionCache.self, in: container) == 1)

        let actor = BackgroundCacheActor(container: container)
        await actor.deleteRecord(recordName: recordName, type: .questCompletion)

        #expect(try remainingCount(QuestCompletionCache.self, in: container) == 0)
    }

    @Test
    func `deleting each entity type removes the correct cache row`() async throws {
        let container = try makeContainer()
        try seedAllCaches(container, prefix: "seed_")

        // Sanity: every cache has exactly one seeded row before deletion.
        #expect(try remainingCount(ProfileCache.self, in: container) == 1)
        #expect(try remainingCount(FamilyCache.self, in: container) == 1)
        #expect(try remainingCount(QuestCache.self, in: container) == 1)
        #expect(try remainingCount(QuestTemplateCache.self, in: container) == 1)
        #expect(try remainingCount(QuestCompletionCache.self, in: container) == 1)
        #expect(try remainingCount(LedgerEntryCache.self, in: container) == 1)
        #expect(try remainingCount(AllowancePeriodCache.self, in: container) == 1)
        #expect(try remainingCount(AchievementCache.self, in: container) == 1)
        #expect(try remainingCount(ProfileAchievementCache.self, in: container) == 1)
        #expect(try remainingCount(NotificationPreferenceCache.self, in: container) == 1)

        let actor = BackgroundCacheActor(container: container)

        await actor.deleteRecord(recordName: "seed_profile", type: .profile)
        await actor.deleteRecord(recordName: "seed_family", type: .family)
        await actor.deleteRecord(recordName: "seed_quest", type: .quest)
        await actor.deleteRecord(recordName: "seed_questTemplate", type: .questTemplate)
        await actor.deleteRecord(recordName: "seed_questCompletion", type: .questCompletion)
        await actor.deleteRecord(recordName: "seed_ledgerEntry", type: .ledgerEntry)
        await actor.deleteRecord(recordName: "seed_allowancePeriod", type: .allowancePeriod)
        await actor.deleteRecord(recordName: "seed_achievement", type: .achievement)
        await actor.deleteRecord(recordName: "seed_profileAchievement", type: .profileAchievement)
        await actor.deleteRecord(recordName: "seed_notificationPreference", type: .notificationPreference)

        #expect(try remainingCount(ProfileCache.self, in: container) == 0)
        #expect(try remainingCount(FamilyCache.self, in: container) == 0)
        #expect(try remainingCount(QuestCache.self, in: container) == 0)
        #expect(try remainingCount(QuestTemplateCache.self, in: container) == 0)
        #expect(try remainingCount(QuestCompletionCache.self, in: container) == 0)
        #expect(try remainingCount(LedgerEntryCache.self, in: container) == 0)
        #expect(try remainingCount(AllowancePeriodCache.self, in: container) == 0)
        #expect(try remainingCount(AchievementCache.self, in: container) == 0)
        #expect(try remainingCount(ProfileAchievementCache.self, in: container) == 0)
        #expect(try remainingCount(NotificationPreferenceCache.self, in: container) == 0)
    }

    @Test
    func `unknown recordType is skipped without throwing`() async throws {
        // The skip happens at the SyncEngine layer via the resolver; the actor
        // itself only ever receives typed cases. An unknown CKRecordType string
        // resolves to nil and would be `continue`d by the caller.
        #expect(CachedRecordType.recordType(for: "UnknownType") == nil)
        #expect(CachedRecordType.recordType(for: "") == nil)

        // Deleting a nonexistent record name with a valid type must not throw
        // and must leave the store untouched.
        let container = try makeContainer()
        let actor = BackgroundCacheActor(container: container)
        await actor.deleteRecord(recordName: "does_not_exist", type: .quest)

        #expect(try remainingCount(QuestCache.self, in: container) == 0)
    }

    // MARK: - Batch Upsert & Purge Tests

    private func ref(_ name: String) -> CKRecord.Reference {
        CKRecord.Reference(recordID: CKRecord.ID(recordName: name), action: .none)
    }

    private func fetchAll<T: PersistentModel>(_: T.Type, in container: ModelContainer) throws -> [T] {
        try ModelContext(container).fetch(FetchDescriptor<T>())
    }

    // MARK: Families

    @Test
    func `batch upsert families inserts new records`() async throws {
        let container = try makeContainer()
        let actor = BackgroundCacheActor(container: container)

        let family1 = Family(
            name: "Dragons",
            createdBy: CKRecord.ID(recordName: "user1"),
            id: CKRecord.ID(recordName: "fam1")
        )
        let family2 = Family(
            name: "Unicorns",
            createdBy: CKRecord.ID(recordName: "user2"),
            id: CKRecord.ID(recordName: "fam2")
        )

        await actor.batchUpsertFamilies([family1, family2])

        #expect(try remainingCount(FamilyCache.self, in: container) == 2)
    }

    @Test
    func `batch upsert families updates existing records`() async throws {
        let container = try makeContainer()
        try seedAllCaches(container, prefix: "existing_")
        #expect(try remainingCount(FamilyCache.self, in: container) == 1)

        let actor = BackgroundCacheActor(container: container)
        let updated = Family(
            name: "Updated Name",
            createdBy: CKRecord.ID(recordName: "user1"),
            id: CKRecord.ID(recordName: "existing_family")
        )

        await actor.batchUpsertFamilies([updated])

        #expect(try remainingCount(FamilyCache.self, in: container) == 1)
        let families = try fetchAll(FamilyCache.self, in: container)
        #expect(families.first?.name == "Updated Name")
    }

    @Test
    func `purge missing families removes records not in set`() async throws {
        let container = try makeContainer()
        try seedAllCaches(container, prefix: "a_")
        try seedAllCaches(container, prefix: "b_")
        #expect(try remainingCount(FamilyCache.self, in: container) == 2)

        let actor = BackgroundCacheActor(container: container)
        await actor.purgeMissingFamilies(validRecordNames: ["a_family"])

        #expect(try remainingCount(FamilyCache.self, in: container) == 1)
        let families = try fetchAll(FamilyCache.self, in: container)
        #expect(families.first?.recordName == "a_family")
    }

    @Test
    func `purge missing families keeps records in set`() async throws {
        let container = try makeContainer()
        try seedAllCaches(container, prefix: "x_")
        try seedAllCaches(container, prefix: "y_")
        #expect(try remainingCount(FamilyCache.self, in: container) == 2)

        let actor = BackgroundCacheActor(container: container)
        await actor.purgeMissingFamilies(validRecordNames: ["x_family", "y_family"])

        #expect(try remainingCount(FamilyCache.self, in: container) == 2)
    }

    @Test
    func `batch upsert families empty array clears nothing`() async throws {
        let container = try makeContainer()
        try seedAllCaches(container, prefix: "seed_")
        #expect(try remainingCount(FamilyCache.self, in: container) == 1)

        let actor = BackgroundCacheActor(container: container)
        await actor.batchUpsertFamilies([])

        #expect(try remainingCount(FamilyCache.self, in: container) == 1)
    }

    @Test
    func `purge missing families empty set removes all`() async throws {
        let container = try makeContainer()
        try seedAllCaches(container, prefix: "seed_")
        #expect(try remainingCount(FamilyCache.self, in: container) == 1)

        let actor = BackgroundCacheActor(container: container)
        await actor.purgeMissingFamilies(validRecordNames: [])

        #expect(try remainingCount(FamilyCache.self, in: container) == 0)
    }

    // MARK: - Purge family-scope guard

    @Test
    func `purge with nil family does not delete rows of a different family`() async throws {
        let container = try makeContainer()
        let actor = BackgroundCacheActor(container: container)

        // Two families' quest rows share the store; the purge must be
        // family-scoped — calling purge with nil scope must be a
        // no-op, never a global delete that would wipe another family's rows.
        let now = Date()
        let ctx = ModelContext(container)
        ctx.insert(QuestCache(
            recordName: "q_a", familyRecordName: "fam_a", assigneeRecordName: "hero",
            templateRecordName: "tpl", weekOf: now, questName: "Q-A", isActive: true,
            goldReward: 1, xpReward: 10, rarity: "common", scheduleType: "weeklyFlexible",
            isAllOrNothing: false, approvalMode: "autoApprove", descriptionText: nil,
            createdByRecordName: "user1"
        ))
        ctx.insert(QuestCache(
            recordName: "q_b", familyRecordName: "fam_b", assigneeRecordName: "hero",
            templateRecordName: "tpl", weekOf: now, questName: "Q-B", isActive: true,
            goldReward: 1, xpReward: 10, rarity: "common", scheduleType: "weeklyFlexible",
            isAllOrNothing: false, approvalMode: "autoApprove", descriptionText: nil,
            createdByRecordName: "user1"
        ))
        try ctx.save()

        #expect(try remainingCount(QuestCache.self, in: container) == 2)

        // A nil scope must be a no-op.
        await actor.purgeMissingQuests(validRecordNames: [], familyRecordName: nil)
        #expect(try remainingCount(QuestCache.self, in: container) == 2)

        // An empty scope must also be a no-op.
        await actor.purgeMissingQuests(validRecordNames: [], familyRecordName: "")
        #expect(try remainingCount(QuestCache.self, in: container) == 2)

        // Sanity: an explicitly scoped purge still works — scope fam_a with
        // empty valid set deletes only fam_a's row, leaving fam_b intact.
        await actor.purgeMissingQuests(validRecordNames: [], familyRecordName: "fam_a")
        #expect(try remainingCount(QuestCache.self, in: container) == 1)
        let remaining = try fetchAll(QuestCache.self, in: container)
        #expect(remaining.first?.familyRecordName == "fam_b")
    }

    // MARK: Quests

    @Test
    func `batch upsert quests inserts new records`() async throws {
        let container = try makeContainer()
        let actor = BackgroundCacheActor(container: container)

        let quest1 = Quest(
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
        let quest2 = Quest(
            template: ref("tpl"),
            assignee: ref("hero"),
            goldReward: 10.0,
            xpReward: 100,
            scheduleType: .weeklyFlexible,
            approvalMode: .autoApprove,
            weekOf: Date(),
            createdBy: ref("user1"),
            family: ref("fam"),
            name: "Do Dishes",
            id: CKRecord.ID(recordName: "quest2")
        )

        await actor.batchUpsertQuests([quest1, quest2])

        #expect(try remainingCount(QuestCache.self, in: container) == 2)
    }

    @Test
    func `batch upsert quests updates existing records`() async throws {
        let container = try makeContainer()
        try seedAllCaches(container, prefix: "existing_")
        #expect(try remainingCount(QuestCache.self, in: container) == 1)

        let actor = BackgroundCacheActor(container: container)
        let updated = Quest(
            template: ref("tpl"),
            assignee: ref("hero"),
            goldReward: 99.0,
            xpReward: 999,
            scheduleType: .weeklyFlexible,
            approvalMode: .autoApprove,
            weekOf: Date(),
            createdBy: ref("user1"),
            family: ref("fam"),
            name: "Updated Quest",
            id: CKRecord.ID(recordName: "existing_quest")
        )

        await actor.batchUpsertQuests([updated])

        #expect(try remainingCount(QuestCache.self, in: container) == 1)
        let quests = try fetchAll(QuestCache.self, in: container)
        #expect(quests.first?.questName == "Updated Quest")
        #expect(quests.first?.goldReward == 99.0)
    }

    @Test
    func `purge missing quests removes records not in set`() async throws {
        let container = try makeContainer()
        try seedAllCaches(container, prefix: "a_")
        try seedAllCaches(container, prefix: "b_")
        #expect(try remainingCount(QuestCache.self, in: container) == 2)

        let actor = BackgroundCacheActor(container: container)
        await actor.purgeMissingQuests(validRecordNames: ["a_quest"], familyRecordName: "fam")

        #expect(try remainingCount(QuestCache.self, in: container) == 1)
    }

    // MARK: Quest Templates

    @Test
    func `batch upsert quest templates inserts new records`() async throws {
        let container = try makeContainer()
        let actor = BackgroundCacheActor(container: container)

        let template1 = QuestTemplate(
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
        let template2 = QuestTemplate(
            name: "Walk Dog",
            description: "Take the dog for a walk",
            defaultGold: 10.0,
            xpReward: 100,
            scheduleType: .weeklyFlexible,
            approvalMode: .parentVerify,
            createdBy: ref("user1"),
            family: ref("fam"),
            id: CKRecord.ID(recordName: "tpl2")
        )

        await actor.batchUpsertQuestTemplates([template1, template2])

        #expect(try remainingCount(QuestTemplateCache.self, in: container) == 2)
    }

    @Test
    func `purge missing quest templates removes records not in set`() async throws {
        let container = try makeContainer()
        try seedAllCaches(container, prefix: "a_")
        try seedAllCaches(container, prefix: "b_")
        #expect(try remainingCount(QuestTemplateCache.self, in: container) == 2)

        let actor = BackgroundCacheActor(container: container)
        await actor.purgeMissingQuestTemplates(validRecordNames: ["a_questTemplate"], familyRecordName: "fam")

        #expect(try remainingCount(QuestTemplateCache.self, in: container) == 1)
    }

    // MARK: Quest Completions

    @Test
    func `batch upsert quest completions inserts new records`() async throws {
        let container = try makeContainer()
        let actor = BackgroundCacheActor(container: container)

        let now = Date()
        let comp1 = QuestCompletion(
            quest: ref("quest"),
            completedBy: ref("hero"),
            approvalMode: .parentVerify,
            completedDate: now,
            weekOf: now,
            family: ref("fam"),
            id: CKRecord.ID(recordName: "comp1")
        )
        let comp2 = QuestCompletion(
            quest: ref("quest"),
            completedBy: ref("hero"),
            approvalMode: .autoApprove,
            completedDate: now,
            weekOf: now,
            family: ref("fam"),
            id: CKRecord.ID(recordName: "comp2")
        )

        await actor.batchUpsertQuestCompletions([comp1, comp2])

        #expect(try remainingCount(QuestCompletionCache.self, in: container) == 2)
    }

    @Test
    func `purge missing quest completions removes records not in set`() async throws {
        let container = try makeContainer()
        try seedAllCaches(container, prefix: "a_")
        try seedAllCaches(container, prefix: "b_")
        #expect(try remainingCount(QuestCompletionCache.self, in: container) == 2)

        let actor = BackgroundCacheActor(container: container)
        await actor.purgeMissingQuestCompletions(validRecordNames: ["a_questCompletion"], familyRecordName: "fam")

        #expect(try remainingCount(QuestCompletionCache.self, in: container) == 1)
    }

    // MARK: Profiles

    @Test
    func `batch upsert profiles inserts new records`() async throws {
        let container = try makeContainer()
        let actor = BackgroundCacheActor(container: container)

        let profile1 = Profile(
            displayName: "Hero",
            role: .hero,
            iCloudUserID: CKRecord.ID(recordName: "icloud1"),
            family: ref("fam"),
            id: CKRecord.ID(recordName: "profile1")
        )
        let profile2 = Profile(
            displayName: "Parent",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "icloud2"),
            family: ref("fam"),
            id: CKRecord.ID(recordName: "profile2")
        )

        await actor.batchUpsertProfiles([profile1, profile2])

        #expect(try remainingCount(ProfileCache.self, in: container) == 2)
    }

    @Test
    func `purge missing profiles removes records not in set`() async throws {
        let container = try makeContainer()
        try seedAllCaches(container, prefix: "a_")
        try seedAllCaches(container, prefix: "b_")
        #expect(try remainingCount(ProfileCache.self, in: container) == 2)

        let actor = BackgroundCacheActor(container: container)
        await actor.purgeMissingProfiles(validRecordNames: ["a_profile"], familyRecordName: "fam")

        #expect(try remainingCount(ProfileCache.self, in: container) == 1)
    }

    // MARK: Ledger Entries

    @Test
    func `batch upsert ledger entries inserts new records`() async throws {
        let container = try makeContainer()
        let actor = BackgroundCacheActor(container: container)

        let entry1 = LedgerEntry(
            profile: ref("hero"),
            amount: 5.0,
            description: "Bonus",
            family: ref("fam"),
            id: CKRecord.ID(recordName: "entry1")
        )
        let entry2 = LedgerEntry(
            profile: ref("hero"),
            amount: 10.0,
            description: "Reward",
            family: ref("fam"),
            id: CKRecord.ID(recordName: "entry2")
        )

        await actor.batchUpsertLedgerEntries([entry1, entry2])

        #expect(try remainingCount(LedgerEntryCache.self, in: container) == 2)
    }

    // MARK: Allowance Periods

    @Test
    func `batch upsert allowance periods inserts new records`() async throws {
        let container = try makeContainer()
        let actor = BackgroundCacheActor(container: container)

        let period1 = AllowancePeriod(
            weekOf: Date(),
            profile: ref("hero"),
            questsTotal: 5,
            family: ref("fam"),
            id: CKRecord.ID(recordName: "period1")
        )
        let period2 = AllowancePeriod(
            weekOf: Date(),
            profile: ref("hero"),
            questsTotal: 10,
            family: ref("fam"),
            id: CKRecord.ID(recordName: "period2")
        )

        await actor.batchUpsertAllowancePeriods([period1, period2])

        #expect(try remainingCount(AllowancePeriodCache.self, in: container) == 2)
    }

    // MARK: Achievements

    @Test
    func `batch upsert achievements inserts new records`() async throws {
        let container = try makeContainer()
        let actor = BackgroundCacheActor(container: container)

        let ach1 = Achievement(
            name: "First Quest",
            description: "Complete your first quest",
            iconSystemName: "star.fill",
            category: .quest,
            requirementType: .firstQuest,
            requirementValue: 1,
            family: ref("fam"),
            id: CKRecord.ID(recordName: "ach1")
        )
        let ach2 = Achievement(
            name: "Quest Master",
            description: "Complete 10 quests",
            iconSystemName: "star.circle.fill",
            category: .quest,
            requirementType: .questCount10,
            requirementValue: 10,
            family: ref("fam"),
            id: CKRecord.ID(recordName: "ach2")
        )

        await actor.batchUpsertAchievements([ach1, ach2])

        #expect(try remainingCount(AchievementCache.self, in: container) == 2)
    }

    // MARK: Profile Achievements

    @Test
    func `batch upsert profile achievements inserts new records`() async throws {
        let container = try makeContainer()
        let actor = BackgroundCacheActor(container: container)

        let pa1 = ProfileAchievement(
            achievement: ref("ach"),
            profile: ref("hero"),
            family: ref("fam"),
            id: CKRecord.ID(recordName: "pa1")
        )
        let pa2 = ProfileAchievement(
            achievement: ref("ach"),
            profile: ref("hero"),
            family: ref("fam"),
            id: CKRecord.ID(recordName: "pa2")
        )

        await actor.batchUpsertProfileAchievements([pa1, pa2])

        #expect(try remainingCount(ProfileAchievementCache.self, in: container) == 2)
    }

    // MARK: Notification Preferences

    @Test
    func `batch upsert notification preferences inserts new records`() async throws {
        let container = try makeContainer()
        let actor = BackgroundCacheActor(container: container)

        let pref1 = NotificationPreference(
            profile: ref("hero"),
            eventType: .questCompleted,
            enabled: true,
            pushEnabled: true,
            family: ref("fam"),
            id: CKRecord.ID(recordName: "pref1")
        )
        let pref2 = NotificationPreference(
            profile: ref("hero"),
            eventType: .levelUp,
            enabled: false,
            pushEnabled: false,
            family: ref("fam"),
            id: CKRecord.ID(recordName: "pref2")
        )

        await actor.batchUpsertNotificationPreferences([pref1, pref2])

        #expect(try remainingCount(NotificationPreferenceCache.self, in: container) == 2)
    }
}
