//
//  BackgroundCacheActorTests.swift
//  LootList
//
//  Unit tests for the typed `CachedRecordType` delete path in
//  `BackgroundCacheActor`. Guards against the Swift class-name /
//  CloudKit `CKRecordType` divergence bug (notably `QuestCompletion`
//  whose `recordType == "QuestLog"`).
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

        let actor = BackgroundCacheActor(modelContainer: container)
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

        let actor = BackgroundCacheActor(modelContainer: container)

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
        let actor = BackgroundCacheActor(modelContainer: container)
        await actor.deleteRecord(recordName: "does_not_exist", type: .quest)

        #expect(try remainingCount(QuestCache.self, in: container) == 0)
    }
}
