//
//  QuestServiceTests+Queries.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

extension QuestServiceTests {
    // MARK: - Review remediation: no ad-hoc post-save CloudKit query

    @Test
    func `markComplete performs no ad-hoc post-save CloudKit query`() async throws {
        // Services must not issue ad-hoc CloudKit refreshes; SyncEngine is
        // the single writer of server-derived state. The pre-remediation code
        // spawned `Task { fetchQuestLogs(useCache: false) }` after the save — a
        // background CloudKit query. That path is removed; `markComplete` must
        // not query CloudKit post-save. To make this deterministic against a
        // fire-and-forget spawned Task, `query` parks the caller until released;
        // if any post-save query were issued, `waitForQueryHit` would resolve.
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = QueryParkingCloudKitService(zoneID: zoneID)
        let scaffold = try MarkCompleteScaffold(cloudKitOverride: cloudKit)

        // Rejected seed keeps the local alreadyCompleted check below target
        // without any CloudKit read.
        scaffold.cache.upsertQuestCompletions([scaffold.completion(status: .rejected)])

        let service = scaffold.questService
        let quest = scaffold.quest
        let hero = scaffold.hero
        _ = try await service.markComplete(quest: quest, by: hero)

        // Give any fire-and-forget spawned `Task` a chance to schedule and enter
        // `cloudKit.query` (which would park). A short hop suffices because the
        // query mock records the hit synchronously on entry.
        try await Task.sleep(for: .milliseconds(50))

        #expect(
            cloudKit.queryHitCount == 0,
            "markComplete must not issue an ad-hoc post-save CloudKit query; SyncEngine is the single writer"
        )

        // Release any (none, post-remediation) parked query so the test cleans up.
        cloudKit.releaseQueries()
    }

    @Test
    func `verify resolves quest and hero from cache with zero CloudKit reads`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = NetworkCountingCloudKitService(zoneID: zoneID)
        let scaffold = try MarkCompleteScaffold(cloudKitOverride: cloudKit)

        // Seed quest, hero, and a pending completion into the cache only.
        scaffold.cache.upsertQuest(scaffold.quest)
        scaffold.cache.upsertProfile(scaffold.hero)
        let pending = scaffold.completion(status: .pending)
        scaffold.cache.upsertQuestCompletion(pending)

        // A completed sync pass stamped this family's quest/profile/completion
        // caches as fresh, so verify's cache-first resolution is trusted.
        scaffold.cache.markCacheFresh(familyRecordName: "fam1", type: .quest)
        scaffold.cache.markCacheFresh(familyRecordName: "fam1", type: .profile)
        scaffold.cache.markCacheFresh(familyRecordName: "fam1", type: .questCompletion)

        let saved = try await scaffold.questService.verify(questLog: pending, by: scaffold.parent)

        #expect(saved.verificationStatus == .verified)
        #expect(
            cloudKit.readCallCount == 0,
            "verify must resolve quest + hero from cache when fresh"
        )

        let cached = scaffold.cache.fetchQuestCompletions(family: scaffold.familyRef.recordID.recordName)
            .first(where: { $0.recordName == pending.id.recordName })
        #expect(
            cached?.toQuestCompletion(zoneID: zoneID).verificationStatus == .verified,
            "Cache must hold the verified completion after verify"
        )
    }

    @Test
    func `reject works from cache with zero CloudKit reads`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = NetworkCountingCloudKitService(zoneID: zoneID)
        let scaffold = try MarkCompleteScaffold(cloudKitOverride: cloudKit)

        let pending = scaffold.completion(status: .pending)
        scaffold.cache.upsertQuestCompletion(pending)

        let saved = try await scaffold.questService.reject(questLog: pending, by: scaffold.parent)

        #expect(saved.verificationStatus == .rejected)
        #expect(
            cloudKit.readCallCount == 0,
            "reject must perform no CloudKit reads"
        )

        let cached = scaffold.cache.fetchQuestCompletions(family: scaffold.familyRef.recordID.recordName)
            .first(where: { $0.recordName == pending.id.recordName })
        #expect(
            cached?.toQuestCompletion(zoneID: zoneID).verificationStatus == .rejected,
            "Cache must hold the rejected completion after reject"
        )
    }

    // MARK: - fetchActiveQuests

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
    func `fetchActiveQuests falls back to CloudKit when cache is stale`() async throws {
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
        let templateRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none
        )

        // Partial cache: a quest WITHOUT a freshness stamp (stale). Explicitly
        // invalidate first — stamps persist in UserDefaults for the process,
        // so a fresh-gate test running earlier must not contaminate this one.
        cache.invalidateFreshness(familyRecordName: "fam1", type: .quest)
        let cachedQuest = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(recordID: profileID, action: .none),
            goldReward: 5.0,
            xpReward: 10,
            scheduleType: .weeklyFlexible,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: monday,
            createdBy: familyRef,
            family: familyRef,
            name: "Cached Quest",
            id: CKRecord.ID(recordName: "quest-cached", zoneID: zoneID)
        )
        cache.upsertQuest(cachedQuest)

        // CloudKit truth: a DIFFERENT quest for the same hero.
        let ckQuest = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(recordID: profileID, action: .none),
            goldReward: 50.0,
            xpReward: 100,
            scheduleType: .weeklyFlexible,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: monday,
            createdBy: familyRef,
            family: familyRef,
            name: "CK Quest",
            id: CKRecord.ID(recordName: "quest-ck", zoneID: zoneID)
        )
        cloudKit.seedMockRecords([ckQuest])

        let results = try await questService.fetchActiveQuests(profile: profile, weekOf: monday)

        // A stale (unstamped) partial cache must NOT be served — the CloudKit
        // query path wins.
        #expect(results.count == 1)
        #expect(results.first?.id.recordName == "quest-ck")
        #expect(results.first?.goldReward == 50.0)
    }

    @Test
    func `fetchActiveQuests serves partial cache when freshness stamp is fresh`() async throws {
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
        let templateRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none
        )

        // Partial cache: a quest WITH a freshness stamp (fresh).
        let cachedQuest = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(recordID: profileID, action: .none),
            goldReward: 5.0,
            xpReward: 10,
            scheduleType: .weeklyFlexible,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: monday,
            createdBy: familyRef,
            family: familyRef,
            name: "Cached Quest",
            id: CKRecord.ID(recordName: "quest-cached", zoneID: zoneID)
        )
        cache.upsertQuest(cachedQuest)
        cache.markCacheFresh(familyRecordName: "fam1", type: .quest)

        // CloudKit holds a DIFFERENT quest — if the gate leaked to CK the
        // result would differ from the cache.
        let ckQuest = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(recordID: profileID, action: .none),
            goldReward: 50.0,
            xpReward: 100,
            scheduleType: .weeklyFlexible,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: monday,
            createdBy: familyRef,
            family: familyRef,
            name: "CK Quest",
            id: CKRecord.ID(recordName: "quest-ck", zoneID: zoneID)
        )
        cloudKit.seedMockRecords([ckQuest])

        let results = try await questService.fetchActiveQuests(profile: profile, weekOf: monday)

        // Fresh partial cache wins — CloudKit is never consulted.
        #expect(results.count == 1)
        #expect(results.first?.id.recordName == "quest-cached")
        #expect(results.first?.goldReward == 5.0)
    }

    // MARK: - Non-Sunday payout day bucketing

    @Test
    func `fetchActiveQuests buckets by the hero's Friday payout override`() async throws {
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
        let heroID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        // The hero overrides the family default: Friday payout cycles.
        let hero = Profile(
            displayName: "Hero",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .hero,
            iCloudUserID: heroID,
            family: familyRef,
            payoutDay: .friday,
            id: heroID
        )
        let templateRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none
        )

        // Friday payout cycles start the day after Friday (Saturday) — NOT the
        // current Monday. The buggy Monday-start range would drop the
        // current-cycle quest below.
        let now = Date()
        let currentCycle = WeekMath.startOfWeek(for: now, payoutDay: .friday)
        let previousCycle = Calendar.iso8601UTC.date(byAdding: .weekOfYear, value: -1, to: currentCycle)
            ?? currentCycle

        let currentQuest = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(recordID: heroID, action: .none),
            goldReward: 10.0,
            xpReward: 20,
            scheduleType: .weeklyFlexible,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: currentCycle,
            createdBy: familyRef,
            family: familyRef,
            name: "Current Cycle Quest",
            id: CKRecord.ID(recordName: "quest-current", zoneID: zoneID)
        )
        let previousQuest = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(recordID: heroID, action: .none),
            goldReward: 99.0,
            xpReward: 200,
            scheduleType: .weeklyFlexible,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: previousCycle,
            createdBy: familyRef,
            family: familyRef,
            name: "Previous Cycle Quest",
            id: CKRecord.ID(recordName: "quest-previous", zoneID: zoneID)
        )
        cache.upsertQuests([currentQuest, previousQuest])
        cache.markCacheFresh(familyRecordName: "fam1", type: .quest)

        let results = try await questService.fetchActiveQuests(profile: hero, weekOf: now)

        #expect(
            results.map(\.id.recordName) == ["quest-current"],
            "fetchActiveQuests must serve the current Friday cycle and exclude the previous cycle"
        )
    }

    @Test
    func `fetchQuestsForFamilyWeek buckets by the family's Friday payout day`() async throws {
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
        let family = Family(
            name: "Friday Guild",
            createdBy: CKRecord.ID(recordName: "owner1", zoneID: zoneID),
            payoutDay: .friday,
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
        let heroID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        let templateRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none
        )

        let now = Date()
        let currentCycle = WeekMath.startOfWeek(for: now, payoutDay: .friday)
        let previousCycle = Calendar.iso8601UTC.date(byAdding: .weekOfYear, value: -1, to: currentCycle)
            ?? currentCycle

        let currentQuest = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(recordID: heroID, action: .none),
            goldReward: 10.0,
            xpReward: 20,
            scheduleType: .weeklyFlexible,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: currentCycle,
            createdBy: familyRef,
            family: familyRef,
            name: "Current Cycle Quest",
            id: CKRecord.ID(recordName: "quest-current", zoneID: zoneID)
        )
        let previousQuest = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(recordID: heroID, action: .none),
            goldReward: 99.0,
            xpReward: 200,
            scheduleType: .weeklyFlexible,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: previousCycle,
            createdBy: familyRef,
            family: familyRef,
            name: "Previous Cycle Quest",
            id: CKRecord.ID(recordName: "quest-previous", zoneID: zoneID)
        )
        cache.upsertQuests([currentQuest, previousQuest])
        cache.markCacheFresh(familyRecordName: "fam1", type: .quest)

        let results = try await questService.fetchQuestsForFamilyWeek(family: family, weekOf: now)

        #expect(
            results.map(\.id.recordName) == ["quest-current"],
            "fetchQuestsForFamilyWeek must serve the current Friday cycle and exclude the previous cycle"
        )
    }

    @Test
    func `earnedThisWeek buckets by the family's Friday payout day`() async throws {
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
        // The family defaults to Friday payouts; the hero inherits it, so the
        // effective payout day must be resolved from the cached family.
        let family = Family(
            name: "Friday Guild",
            createdBy: CKRecord.ID(recordName: "owner1", zoneID: zoneID),
            payoutDay: .friday,
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
        cache.upsertFamily(family)

        let heroID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        let hero = Profile(
            displayName: "Hero",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .hero,
            iCloudUserID: heroID,
            family: familyRef,
            id: heroID
        )
        let templateRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none
        )

        let now = Date()
        let currentCycle = WeekMath.startOfWeek(for: now, payoutDay: .friday)
        let previousCycle = Calendar.iso8601UTC.date(byAdding: .weekOfYear, value: -1, to: currentCycle)
            ?? currentCycle

        let currentQuest = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(recordID: heroID, action: .none),
            goldReward: 10.0,
            xpReward: 20,
            scheduleType: .weeklyFlexible,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: currentCycle,
            createdBy: familyRef,
            family: familyRef,
            name: "Current Cycle Quest",
            id: CKRecord.ID(recordName: "quest-current", zoneID: zoneID)
        )
        let previousQuest = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(recordID: heroID, action: .none),
            goldReward: 99.0,
            xpReward: 200,
            scheduleType: .weeklyFlexible,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: previousCycle,
            createdBy: familyRef,
            family: familyRef,
            name: "Previous Cycle Quest",
            id: CKRecord.ID(recordName: "quest-previous", zoneID: zoneID)
        )
        cache.upsertQuests([currentQuest, previousQuest])

        var currentLog = QuestCompletion(
            quest: CKRecord.Reference(recordID: currentQuest.id, action: .none),
            completedBy: CKRecord.Reference(recordID: heroID, action: .none),
            approvalMode: .autoApprove,
            weekOf: currentCycle,
            family: familyRef,
            id: CKRecord.ID(recordName: "log-current", zoneID: zoneID)
        )
        currentLog.verificationStatus = .autoApproved
        var previousLog = QuestCompletion(
            quest: CKRecord.Reference(recordID: previousQuest.id, action: .none),
            completedBy: CKRecord.Reference(recordID: heroID, action: .none),
            approvalMode: .autoApprove,
            weekOf: previousCycle,
            family: familyRef,
            id: CKRecord.ID(recordName: "log-previous", zoneID: zoneID)
        )
        previousLog.verificationStatus = .autoApproved
        cache.upsertQuestCompletions([currentLog, previousLog])
        cache.markCacheFresh(familyRecordName: "fam1", type: .questCompletion)

        let earned = try await questService.earnedThisWeek(profile: hero, weekOf: now)

        #expect(
            earned == 10.0,
            "earnedThisWeek must count the current Friday cycle's completion (10 gold) and exclude the previous cycle's 99 gold"
        )
    }

    // MARK: - Data Migrations

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
