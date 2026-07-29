//
//  QuestServiceTests.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct QuestServiceTests {
    private func makeTestData() -> (CloudKitService, Profile, Profile, Family) { // swiftlint:disable:this large_tuple
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = CloudKitService(zoneID: zoneID)
        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let userID = CKRecord.ID(recordName: "user1", zoneID: zoneID)

        let parent = Profile(
            displayName: "Parent GM",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .guildMaster,
            iCloudUserID: userID,
            family: familyRef
        )

        let hero = Profile(
            displayName: "Child Hero",
            avatarClass: .mage,
            avatarPresetID: "mage_01",
            role: .hero,
            iCloudUserID: userID,
            family: familyRef
        )

        let family = Family(
            name: "Test Guild",
            createdBy: parent.id,
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )

        return (cloudKit, parent, hero, family)
    }

    @Test
    func `quest service initialization`() {
        let (cloudKit, _, _, _) = makeTestData()
        let xpService = XPService(cloudKit: cloudKit)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService)
        #expect(questService.cloudKitReference === cloudKit)
    }

    @Test
    func `create quest template model instantiation`() async throws {
        let (cloudKit, parent, _, family) = makeTestData()
        let xpService = XPService(cloudKit: cloudKit)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService)

        let template = try await questService.createTemplate(
            name: "Clean Room",
            description: "Tidy up all toys",
            defaultGold: 5.0,
            xpReward: 50,
            schedule: .weeklyFlexible,
            approvalMode: .parentVerify,
            createdBy: parent,
            family: family
        )

        #expect(template.name == "Clean Room")
        #expect(template.description == "Tidy up all toys")
        #expect(template.defaultGold == 5.0)
        #expect(template.xpReward == 50)
        #expect(template.scheduleType == .weeklyFlexible)
        #expect(template.approvalMode == .parentVerify)
        #expect(template.isActive == true)
    }

    @Test
    func `quest schedule types and day properties`() {
        let specific = QuestSchedule.specificDays
        let flexible = QuestSchedule.weeklyFlexible

        #expect(specific.displayName == "Specific Days")
        #expect(flexible.displayName == "Flexible (Any Day)")
        #expect(specific.requiresSpecificDays == true)
        #expect(flexible.requiresSpecificDays == false)
    }

    @Test
    func `quest error types equatable`() {
        #expect(QuestServiceError.missingSession == QuestServiceError.missingSession)
        #expect(QuestServiceError.alreadyCompleted == QuestServiceError.alreadyCompleted)
        #expect(QuestServiceError.alreadyResolved("e1") == QuestServiceError.alreadyResolved("e1"))
        #expect(QuestServiceError.alreadyResolved("e1") != QuestServiceError.alreadyResolved("e2"))
        #expect(QuestServiceError.missingRecord("r1") == QuestServiceError.missingRecord("r1"))
    }

    @Test
    func `weekRange is half-open and agrees with WeekMath and TreasuryService`() {
        let monday = WeekMath.mondayOfWeek(for: Date())

        let questRange = QuestService.weekRange(for: monday)
        let weekMathRange = WeekMath.weekRange(starting: monday)
        let treasuryRange = TreasuryService.weekRange(starting: monday)

        #expect(questRange == weekMathRange)
        #expect(questRange == treasuryRange)
        #expect(questRange.upperBound.timeIntervalSince(questRange.lowerBound)
            == Double(AppConstants.Time.secondsInWeek))
    }

    @Test
    func `completion at last second of week is included by QuestService`() {
        let monday = WeekMath.mondayOfWeek(for: Date())
        let secondsInWeek = TimeInterval(AppConstants.Time.secondsInWeek)
        let lastSecond = monday.addingTimeInterval(secondsInWeek - 1)

        let questRange = QuestService.weekRange(for: monday)

        #expect(questRange.contains(lastSecond))
    }

    @Test
    func `completion at exactly start + secondsInWeek belongs to next week`() {
        let monday = WeekMath.mondayOfWeek(for: Date())
        let secondsInWeek = TimeInterval(AppConstants.Time.secondsInWeek)
        let nextWeekStart = monday.addingTimeInterval(secondsInWeek)

        let questRange = QuestService.weekRange(for: monday)
        let nextQuestRange = QuestService.weekRange(for: nextWeekStart)

        // Excluded from THIS week (half-open upper bound)...
        #expect(!questRange.contains(nextWeekStart))
        // ...and included by the NEXT week's range.
        #expect(nextQuestRange.contains(nextWeekStart))
    }

    @Test
    func `mondayOfWeek is consistent across all callers`() {
        let now = Date()

        let weekMath = WeekMath.mondayOfWeek(for: now)
        let weekMathAlias = WeekMath.weekOf(date: now)
        let quest = QuestService.mondayOfWeek(for: now)
        let treasury = TreasuryService.mondayOfWeek(for: now)

        #expect(weekMath == weekMathAlias)
        #expect(weekMath == quest)
        #expect(weekMath == treasury)
    }

    @Test
    func `earnedThisWeek reads gold from cache with zero CloudKit fetches`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = CloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let xpService = XPService(cloudKit: cloudKit)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService)
        questService.cacheService = cache

        let familyRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
        )
        let profileID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        // Use `id: profileID` so profile.id.recordName == "hero1" — the production
        // cache filters / CK query predicates key off `profile.id.recordName`
        // (e.g. `$0.completerRecordName == profile.id.recordName`), and the seeded
        // QuestCompletion.completedBy references `profileID`. They must match.
        let profile = Profile(
            displayName: "Hero",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .hero,
            iCloudUserID: profileID,
            family: familyRef,
            id: profileID
        )

        let monday = WeekMath.mondayOfWeek(for: Date())
        let questID = CKRecord.ID(recordName: "quest1", zoneID: zoneID)
        let templateRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none
        )

        let quest = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(recordID: profileID, action: .none),
            goldReward: 40.0,
            xpReward: 80,
            scheduleType: .weeklyFlexible,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: monday,
            createdBy: familyRef,
            family: familyRef,
            name: "Cached Quest",
            id: questID
        )

        let completion = QuestCompletion(
            quest: CKRecord.Reference(recordID: questID, action: .none),
            completedBy: CKRecord.Reference(recordID: profileID, action: .none),
            approvalMode: .autoApprove,
            weekOf: monday,
            family: familyRef
        )

        cache.upsertQuest(quest)
        cache.upsertQuestCompletions([completion])

        let earned = try await questService.earnedThisWeek(profile: profile, weekOf: monday)

        // Gold must come from cache (40.0).  If code hit CK instead,
        // gold would be 0 (empty mockRecords → try? swallows fetch errors).
        #expect(earned == 40.0)
    }

    @Test
    func `earnedThisWeek falls back to CloudKit on cache miss`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = CloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let xpService = XPService(cloudKit: cloudKit)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService)
        questService.cacheService = cache

        let familyRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
        )
        let profileID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        // Use `id: profileID` so profile.id.recordName == "hero1" — the production
        // CK query predicate is `completedBy == <profile.id>`; the seeded
        // QuestCompletion.completedBy references `profileID`. They must match.
        let profile = Profile(
            displayName: "Hero",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .hero,
            iCloudUserID: profileID,
            family: familyRef,
            id: profileID
        )

        let monday = WeekMath.mondayOfWeek(for: Date())
        let questID = CKRecord.ID(recordName: "quest1", zoneID: zoneID)
        let templateRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none
        )

        let quest = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(recordID: profileID, action: .none),
            goldReward: 35.0,
            xpReward: 70,
            scheduleType: .weeklyFlexible,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: monday,
            createdBy: familyRef,
            family: familyRef,
            name: "CK Quest",
            id: questID
        )

        let completion = QuestCompletion(
            quest: CKRecord.Reference(recordID: questID, action: .none),
            completedBy: CKRecord.Reference(recordID: profileID, action: .none),
            approvalMode: .autoApprove,
            weekOf: monday,
            family: familyRef
        )

        // Seed CloudKit only — cache is empty (cache-miss scenario).
        cloudKit.seedMockRecords([quest, completion])

        let earned = try await questService.earnedThisWeek(profile: profile, weekOf: monday)

        // Gold must come from CloudKit fallback (35.0).
        #expect(earned == 35.0)
    }

    @MainActor
    private struct MarkCompleteScaffold {
        let zoneID: CKRecordZone.ID
        let cloudKit: CloudKitService
        let cache: CacheService
        let questService: QuestService
        let familyRef: CKRecord.Reference
        let parent: Profile
        let hero: Profile
        let quest: Quest
        let questRef: CKRecord.Reference

        init(approvalMode: ApprovalMode = .parentVerify) throws {
            zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
            cloudKit = CloudKitService(zoneID: zoneID)
            cache = try CacheService(inMemory: true)
            questService = QuestService(cloudKit: cloudKit, xpService: XPService(cloudKit: cloudKit))
            questService.cacheService = cache

            familyRef = CKRecord.Reference(
                recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
            )
            let parentID = CKRecord.ID(recordName: "parent1", zoneID: zoneID)
            parent = Profile(
                displayName: "Parent GM",
                avatarClass: .knight,
                avatarPresetID: "knight_01",
                role: .guildMaster,
                iCloudUserID: parentID,
                family: familyRef
            )
            let heroID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
            hero = Profile(
                displayName: "Hero",
                avatarClass: .mage,
                avatarPresetID: "mage_01",
                role: .hero,
                iCloudUserID: heroID,
                family: familyRef
            )

            let questID = CKRecord.ID(recordName: "quest1", zoneID: zoneID)
            let templateRef = CKRecord.Reference(
                recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none
            )
            questRef = CKRecord.Reference(recordID: questID, action: .none)
            quest = Quest(
                template: templateRef,
                assignee: CKRecord.Reference(recordID: heroID, action: .none),
                goldReward: 10.0,
                xpReward: 20,
                scheduleType: .weeklyFlexible,
                isAllOrNothing: false,
                approvalMode: approvalMode,
                weekOf: WeekMath.mondayOfWeek(for: Date()),
                createdBy: CKRecord.Reference(recordID: parentID, action: .none),
                family: familyRef,
                name: "Guard Quest",
                id: questID
            )
        }

        func completion(status: VerificationStatus,
                        recordName: String = "log1") -> QuestCompletion
        {
            var log = QuestCompletion(
                quest: questRef,
                completedBy: CKRecord.Reference(recordID: hero.id, action: .none),
                approvalMode: .parentVerify,
                weekOf: quest.weekOf,
                family: familyRef,
                id: CKRecord.ID(recordName: recordName, zoneID: zoneID)
            )
            log.verificationStatus = status
            return log
        }
    }

    @Test
    func `markComplete throws alreadyCompleted when cache stale pending but CK verified`() async throws {
        let scaffold = try MarkCompleteScaffold()

        // Stale cache: a pending log for this quest.
        scaffold.cache.upsertQuestCompletions([scaffold.completion(status: .pending)])
        // CloudKit truth: a verified log for this quest.
        scaffold.cloudKit.seedMockRecords([scaffold.completion(status: .verified)])

        await #expect(throws: QuestServiceError.alreadyCompleted) {
            try await scaffold.questService.markComplete(quest: scaffold.quest, by: scaffold.hero)
        }
    }

    @Test
    func `markComplete throws alreadyCompleted when cache empty but CK verified`() async throws {
        let scaffold = try MarkCompleteScaffold()

        // Cache deliberately empty (no stale state at all).
        // CloudKit truth: a verified log for this quest.
        scaffold.cloudKit.seedMockRecords([scaffold.completion(status: .verified)])

        await #expect(throws: QuestServiceError.alreadyCompleted) {
            try await scaffold.questService.markComplete(quest: scaffold.quest, by: scaffold.hero)
        }
    }

    @Test
    func `markComplete CK truth overrides stale cache rejected log`() async throws {
        let scaffold = try MarkCompleteScaffold()

        scaffold.cache.upsertQuestCompletions([scaffold.completion(status: .rejected)])
        scaffold.cloudKit.seedMockRecords([scaffold.completion(status: .pending)])

        await #expect(throws: QuestServiceError.alreadyCompleted) {
            try await scaffold.questService.markComplete(quest: scaffold.quest, by: scaffold.hero)
        }
    }

    @Test
    func `fetchActiveQuests makes zero CloudKit save calls`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = CloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let xpService = XPService(cloudKit: cloudKit)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService)
        questService.cacheService = cache

        cloudKit.activeFamilyZoneID = zoneID

        let familyRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
        )
        let profileID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        // Use `id: profileID` so profile.id.recordName == "hero1" — fetchActiveQuests
        // issues the CK query `assignee == <profile.id>`; the seeded Quest.assignee
        let profile = Profile(
            displayName: "Hero",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .hero,
            iCloudUserID: profileID,
            family: familyRef,
            id: profileID
        )

        let monday = WeekMath.mondayOfWeek(for: Date())
        let templateID = CKRecord.ID(recordName: "tmpl1", zoneID: zoneID)
        let templateRef = CKRecord.Reference(recordID: templateID, action: .none)
        let questID = CKRecord.ID(recordName: "quest1", zoneID: zoneID)

        // Seed template in CK (needed by stampNameIfNeeded to resolve the name).
        let template = QuestTemplate(
            name: "Clean Room",
            description: "Tidy up",
            defaultGold: 5.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            createdBy: familyRef,
            family: familyRef,
            id: templateID
        )

        // Seed quest with nil name in CK (NOT in cache — forces the CK path).
        let quest = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(recordID: profileID, action: .none),
            goldReward: 10.0,
            xpReward: 20,
            scheduleType: .weeklyFlexible,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: monday,
            createdBy: familyRef,
            family: familyRef,
            name: nil,
            id: questID
        )

        cloudKit.seedMockRecords([template, quest])

        // Confirm: quest starts with nil name in CK.
        let before = try await cloudKit.fetch(Quest.self, id: questID)
        #expect(before.name == nil, "Precondition: quest must start with nil name")

        // Act — cache is empty so this takes the CK query path.
        let results = try await questService.fetchActiveQuests(profile: profile, weekOf: monday)
        #expect(!results.isEmpty, "Should return the quest from CK")

        // If stampNameIfNeeded called cloudKit.save, the name would be stamped.
        let after = try await cloudKit.fetch(Quest.self, id: questID)
        #expect(after.name == nil,
                "fetchActiveQuests must NOT save to CloudKit — name backfill belongs in the launch migration")
    }

    @Test
    func `questNameBackfillV1 saves quests with missing names to CloudKit`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = CloudKitService(zoneID: zoneID)
        cloudKit.activeFamilyZoneID = zoneID

        let familyRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
        )

        let templateID = CKRecord.ID(recordName: "tmpl1", zoneID: zoneID)
        let templateRef = CKRecord.Reference(recordID: templateID, action: .none)
        let questID = CKRecord.ID(recordName: "quest1", zoneID: zoneID)

        // Seed template with a known name.
        let template = QuestTemplate(
            name: "Clean Room",
            description: "Tidy up",
            defaultGold: 5.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            createdBy: familyRef,
            family: familyRef,
            id: templateID
        )

        // Seed quest with nil name.
        let quest = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(
                recordID: CKRecord.ID(recordName: "hero1", zoneID: zoneID), action: .none
            ),
            goldReward: 10.0,
            xpReward: 20,
            scheduleType: .weeklyFlexible,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: WeekMath.mondayOfWeek(for: Date()),
            createdBy: familyRef,
            family: familyRef,
            name: nil,
            id: questID
        )

        cloudKit.seedMockRecords([template, quest])

        // Act — run the migration step directly.
        let step = DataMigrationsCoordinator.questNameBackfillV1(cloudKit: cloudKit)
        try await step.run()

        let saved = try await cloudKit.fetch(Quest.self, id: questID)
        #expect(saved.name == "Clean Room",
                "Migration must backfill nil quest names from the template")
    }

    @Test
    func `questNameBackfillV1 is idempotent on already-backfilled store`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = CloudKitService(zoneID: zoneID)
        cloudKit.activeFamilyZoneID = zoneID

        let familyRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
        )

        let templateID = CKRecord.ID(recordName: "tmpl1", zoneID: zoneID)
        let templateRef = CKRecord.Reference(recordID: templateID, action: .none)
        let questID = CKRecord.ID(recordName: "quest1", zoneID: zoneID)

        let template = QuestTemplate(
            name: "Clean Room",
            description: "Tidy up",
            defaultGold: 5.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            createdBy: familyRef,
            family: familyRef,
            id: templateID
        )

        // Quest already has a name — migration should skip it.
        let quest = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(
                recordID: CKRecord.ID(recordName: "hero1", zoneID: zoneID), action: .none
            ),
            goldReward: 10.0,
            xpReward: 20,
            scheduleType: .weeklyFlexible,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: WeekMath.mondayOfWeek(for: Date()),
            createdBy: familyRef,
            family: familyRef,
            name: "Already Named",
            id: questID
        )

        cloudKit.seedMockRecords([template, quest])

        // Act — run migration; should be a no-op.
        let step = DataMigrationsCoordinator.questNameBackfillV1(cloudKit: cloudKit)
        try await step.run()

        let fetched = try await cloudKit.fetch(Quest.self, id: questID)
        #expect(fetched.name == "Already Named",
                "Migration must not overwrite existing names")
    }
}
