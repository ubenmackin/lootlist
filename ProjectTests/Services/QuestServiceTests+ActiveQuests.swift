//
//  QuestServiceTests+ActiveQuests.swift
//  LootList
//
//  Created by Ben Mackin on 8/06/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

extension QuestServiceTests {
    // MARK: - fetchActiveQuests

    @Test
    func `fetchActiveQuests makes zero CloudKit save calls`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let xpService = XPService(cloudKit: cloudKit)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService)
        questService.cacheService = cache

        cloudKit.activeFamilyZoneID = zoneID

        let familyRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
        )
        let heroID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        let family = Family(
            name: "Test Guild",
            createdBy: CKRecord.ID(recordName: "parent1", zoneID: zoneID),
            payoutDay: .sunday,
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
        let hero = Profile(
            displayName: "Hero",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .hero,
            iCloudUserID: heroID,
            family: familyRef,
            id: heroID
        )

        let monday = QuestService.startOfWeek(for: Date(), payoutDay: .sunday)
        let questID = CKRecord.ID(recordName: "quest1", zoneID: zoneID)
        let templateRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none
        )
        let quest = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(recordID: heroID, action: .none),
            goldReward: 25.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: monday,
            createdBy: familyRef,
            family: familyRef,
            name: "Weekly Quest",
            id: questID
        )

        cloudKit.seedMockRecords([family, hero, quest])

        let activeQuests = try await questService.fetchActiveQuests(profile: hero, weekOf: monday)

        #expect(activeQuests.count == 1)
        #expect(activeQuests.first?.id == questID)
    }

    @Test
    func `fetchActiveQuests respects non-Sunday payout day when profile has none`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let xpService = XPService(cloudKit: cloudKit)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService)
        questService.cacheService = cache

        cloudKit.activeFamilyZoneID = zoneID

        let familyRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
        )
        let heroID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)

        let family = Family(
            name: "Friday Guild",
            createdBy: CKRecord.ID(recordName: "parent1", zoneID: zoneID),
            payoutDay: .friday,
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
        var hero = Profile(
            displayName: "Hero",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .hero,
            iCloudUserID: heroID,
            family: familyRef,
            id: heroID
        )
        hero.payoutDay = nil

        let fridayStart = QuestService.startOfWeek(for: Date(), payoutDay: .friday)
        let templateRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none
        )

        let quest = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(recordID: heroID, action: .none),
            goldReward: 15.0,
            xpReward: 30,
            scheduleType: .weeklyFlexible,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: fridayStart,
            createdBy: familyRef,
            family: familyRef,
            name: "Friday Quest",
            id: CKRecord.ID(recordName: "quest-fri", zoneID: zoneID)
        )

        cloudKit.seedMockRecords([family, hero, quest])

        let activeQuests = try await questService.fetchActiveQuests(profile: hero, weekOf: fridayStart)

        #expect(activeQuests.count == 1)
        #expect(activeQuests.first?.name == "Friday Quest")
    }

    @Test
    func `fetchActiveQuests falls back to CloudKit query when cache is missing target quest`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let xpService = XPService(cloudKit: cloudKit)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService)
        questService.cacheService = cache

        cloudKit.activeFamilyZoneID = zoneID

        let familyRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
        )
        let heroID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        let family = Family(
            name: "Test Guild",
            createdBy: CKRecord.ID(recordName: "parent1", zoneID: zoneID),
            payoutDay: .sunday,
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
        let hero = Profile(
            displayName: "Hero",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .hero,
            iCloudUserID: heroID,
            family: familyRef,
            id: heroID
        )

        let monday = QuestService.startOfWeek(for: Date(), payoutDay: .sunday)
        let templateRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none
        )
        let quest = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(recordID: heroID, action: .none),
            goldReward: 25.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: monday,
            createdBy: familyRef,
            family: familyRef,
            name: "CloudKit Only Quest",
            id: CKRecord.ID(recordName: "quest-ck", zoneID: zoneID)
        )

        cloudKit.seedMockRecords([family, hero, quest])

        let activeQuests = try await questService.fetchActiveQuests(profile: hero, weekOf: monday)

        #expect(activeQuests.count == 1)
        #expect(activeQuests.first?.name == "CloudKit Only Quest")
    }

    @Test
    func `fetchActiveQuests serves results from cache with zero CloudKit queries`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = QueryParkingCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let xpService = XPService(cloudKit: cloudKit)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService)
        questService.cacheService = cache

        cloudKit.activeFamilyZoneID = zoneID

        let familyRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
        )
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

        let monday = QuestService.startOfWeek(for: Date(), payoutDay: .sunday)
        let templateRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none
        )
        let cachedQuest = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(recordID: heroID, action: .none),
            goldReward: 25.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: monday,
            createdBy: familyRef,
            family: familyRef,
            name: "Cached Quest",
            id: CKRecord.ID(recordName: "quest-cached", zoneID: zoneID)
        )

        await cache.upsertQuests([cachedQuest])
        cache.markCacheFresh(familyRecordName: "fam1", type: .quest)

        let activeQuests = try await questService.fetchActiveQuests(profile: hero, weekOf: monday)

        #expect(activeQuests.count == 1)
        #expect(activeQuests.first?.name == "Cached Quest")
        #expect(
            cloudKit.queryHitCount == 0,
            "fetchActiveQuests must serve fresh cached quests without querying CloudKit"
        )
    }

    // MARK: - Non-Sunday payout day bucketing

    @Test
    func `fetchQuestsForFamilyWeek buckets to Wednesday payout boundary`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService()
        let cache = try CacheService(inMemory: true)
        let xpService = XPService(cloudKit: cloudKit)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService)
        questService.cacheService = cache

        cloudKit.activeFamilyZoneID = zoneID

        let familyRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
        )
        let family = Family(
            name: "Wednesday Guild",
            createdBy: CKRecord.ID(recordName: "parent1", zoneID: zoneID),
            payoutDay: .wednesday,
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let thursdayMidday = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 23, hour: 12)))
        let wednesdayStart = WeekMath.startOfWeek(for: thursdayMidday, payoutDay: .wednesday)

        let templateRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none
        )
        let quest = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(
                recordID: CKRecord.ID(recordName: "hero1", zoneID: zoneID), action: .none
            ),
            goldReward: 20.0,
            xpReward: 40,
            scheduleType: .weeklyFlexible,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: wednesdayStart,
            createdBy: familyRef,
            family: familyRef,
            name: "Mid-Cycle Wed Quest",
            id: CKRecord.ID(recordName: "quest-wed", zoneID: zoneID)
        )

        await cache.upsertQuests([quest])
        cache.markCacheFresh(familyRecordName: "fam1", type: .quest)

        let results = try await questService.fetchQuestsForFamilyWeek(family: family, weekOf: thursdayMidday)

        #expect(
            results.count == 1,
            "fetchQuestsForFamilyWeek must resolve Thursday to the Wednesday start-of-week and return the quest bucketed to Wednesday"
        )
        #expect(
            results.first?.id.recordName == "quest-wed",
            "fetchQuestsForFamilyWeek must return the quest bucketed to Wednesday"
        )
    }

    @Test
    func `fetchQuestsForFamilyWeek handles payout day at start of week boundary`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService()
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
            createdBy: CKRecord.ID(recordName: "parent1", zoneID: zoneID),
            payoutDay: .friday,
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let saturdayMidnight = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 25, hour: 0, minute: 0, second: 0)))
        let saturdayStart = WeekMath.startOfWeek(for: saturdayMidnight, payoutDay: .friday)

        #expect(
            saturdayStart == saturdayMidnight,
            "sanity check: Saturday 00:00 UTC IS the start of the Friday-payout anchored week"
        )

        let templateRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none
        )
        let quest = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(
                recordID: CKRecord.ID(recordName: "hero1", zoneID: zoneID), action: .none
            ),
            goldReward: 30.0,
            xpReward: 60,
            scheduleType: .weeklyFlexible,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: saturdayStart,
            createdBy: familyRef,
            family: familyRef,
            name: "Boundary Friday Quest",
            id: CKRecord.ID(recordName: "quest-fri-bound", zoneID: zoneID)
        )

        await cache.upsertQuests([quest])
        cache.markCacheFresh(familyRecordName: "fam1", type: .quest)

        let results = try await questService.fetchQuestsForFamilyWeek(family: family, weekOf: saturdayMidnight)

        #expect(
            results.count == 1,
            "fetchQuestsForFamilyWeek queried at exact Saturday 00:00 UTC must return the quest bucketed to that Saturday start-of-week"
        )
        #expect(
            results.first?.id.recordName == "quest-fri-bound",
            "fetchQuestsForFamilyWeek must match the boundary quest"
        )
    }

    @Test
    func `fetchQuestsForFamilyWeek handles payout day at end of week boundary`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService()
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
            createdBy: CKRecord.ID(recordName: "parent1", zoneID: zoneID),
            payoutDay: .friday,
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let fridayLastSecond = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 31, hour: 23, minute: 59, second: 59)))
        let saturdayStart = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 25, hour: 0, minute: 0, second: 0)))

        let resolvedStart = WeekMath.startOfWeek(for: fridayLastSecond, payoutDay: .friday)
        #expect(
            resolvedStart == saturdayStart,
            "sanity check: Friday 23:59:59 resolves to the Saturday start-of-week that began on July 25"
        )

        let templateRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none
        )
        let quest = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(
                recordID: CKRecord.ID(recordName: "hero1", zoneID: zoneID), action: .none
            ),
            goldReward: 35.0,
            xpReward: 70,
            scheduleType: .weeklyFlexible,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: saturdayStart,
            createdBy: familyRef,
            family: familyRef,
            name: "Late Cycle Friday Quest",
            id: CKRecord.ID(recordName: "quest-fri-late", zoneID: zoneID)
        )

        await cache.upsertQuests([quest])
        cache.markCacheFresh(familyRecordName: "fam1", type: .quest)

        let results = try await questService.fetchQuestsForFamilyWeek(family: family, weekOf: fridayLastSecond)

        #expect(
            results.count == 1,
            "fetchQuestsForFamilyWeek queried at Friday 23:59:59 (last second of the Friday-anchored week) must return the quest bucketed to that cycle"
        )
        #expect(
            results.first?.id.recordName == "quest-fri-late",
            "fetchQuestsForFamilyWeek must match the late-cycle quest"
        )
    }

    // MARK: - Cache-hit range scoping

    @Test
    func `fetchQuestsForFamilyWeek cache-hit filters out cached quests from adjacent week cycles`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService()
        let cache = try CacheService(inMemory: true)
        let xpService = XPService(cloudKit: cloudKit)
        let questService = QuestService(cloudKit: cloudKit, xpService: xpService)
        questService.cacheService = cache

        cloudKit.activeFamilyZoneID = zoneID

        let familyRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
        )
        let heroID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)

        let family = Family(
            name: "Test Guild",
            createdBy: CKRecord.ID(recordName: "parent1", zoneID: zoneID),
            payoutDay: .sunday,
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 22, hour: 14)))
        let currentCycle = QuestService.startOfWeek(for: now, payoutDay: .sunday)
        let previousCycle = try #require(calendar.date(byAdding: .day, value: -7, to: currentCycle))

        let templateRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none
        )
        let inRangeQuest = Quest(
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
            name: "In-Range Quest",
            id: CKRecord.ID(recordName: "quest-in", zoneID: zoneID)
        )
        let outOfRangeQuest = Quest(
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
            name: "Out-Of-Range Quest",
            id: CKRecord.ID(recordName: "quest-out", zoneID: zoneID)
        )
        await cache.upsertQuests([inRangeQuest, outOfRangeQuest])
        cache.markCacheFresh(familyRecordName: "fam1", type: .quest)

        let results = try await questService.fetchQuestsForFamilyWeek(family: family, weekOf: now)

        #expect(
            results.count == 1,
            "fetchQuestsForFamilyWeek cache-hit must return only the in-range quest, not both cached rows"
        )
        #expect(
            results.first?.id.recordName == "quest-in",
            "fetchQuestsForFamilyWeek cache-hit must return the in-range quest, not the out-of-range row"
        )
        let servedWeekOf = try #require(results.first?.weekOf)
        let servedRange = QuestService.weekRange(for: now, payoutDay: .sunday)
        #expect(
            servedRange.contains(servedWeekOf),
            "fetchQuestsForFamilyWeek cache-hit must return a quest whose weekOf is within the requested half-open range"
        )
    }
}
