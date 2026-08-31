//
//  QuestServiceTests+Sweep.swift
//  LootList
//
//  Created by Ben Mackin on 8/30/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct QuestServiceSweepTests {
    // WHY: Scaffold groups 8 related test fixtures without a large tuple (>2 members).
    private struct Scaffold {
        let cloudKit: MockCloudKitService
        let cache: CacheService
        let appState: AppState
        let questService: QuestService
        let family: Family
        let parent: Profile
        let hero: Profile
        let zoneID: CKRecordZone.ID
    }

    private func makeScaffold(cloudKit: MockCloudKitService? = nil) throws -> Scaffold {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "Owner")
        let ck = cloudKit ?? MockCloudKitService(zoneID: zoneID)
        ck.activeFamilyZoneID = zoneID
        let defaults = UserDefaults.ephemeral()
        let cache = try CacheService(inMemory: true, defaults: defaults)
        let appState = AppState(defaults: defaults)
        appState.familyZoneID = zoneID
        appState.cacheService = cache
        appState.isZoneOwner = true

        let parentID = CKRecord.ID(recordName: "parent1", zoneID: zoneID)
        let family = Family(name: "Test Guild", createdBy: parentID, id: CKRecord.ID(recordName: "fam1", zoneID: zoneID))
        let parent = Profile(
            displayName: "Parent",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .guildMaster,
            iCloudUserID: parentID,
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: parentID
        )
        let heroID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        let hero = Profile(
            displayName: "Hero",
            avatarClass: .mage,
            avatarPresetID: "mage_01",
            role: .hero,
            iCloudUserID: heroID,
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: heroID
        )

        appState.family = family
        appState.currentProfile = parent
        appState.authStatus = .authenticated
        cache.context?.insert(FamilyCache(from: family))
        cache.context?.insert(ProfileCache(from: parent))
        cache.context?.insert(ProfileCache(from: hero))
        _ = cache.saveContext()

        let xp = XPService(cloudKit: ck)
        let questService = QuestService(cloudKit: ck, xpService: xp)
        questService.cacheService = cache
        questService.xpService.cacheService = cache
        questService.appState = appState
        questService.xpService.appState = appState
        appState.cacheService = cache

        return Scaffold(
            cloudKit: ck,
            cache: cache,
            appState: appState,
            questService: questService,
            family: family,
            parent: parent,
            hero: hero,
            zoneID: zoneID
        )
    }

    private func seedQuest(_ cache: CacheService, family: Family, hero: Profile, parent: Profile, weekOf: Date, recordName: String, templateRecordName: String = "tmpl1") async {
        let template = QuestTemplate(
            name: "Quest",
            description: "",
            defaultGold: 5,
            xpReward: 10,
            scheduleType: .weeklyFlexible,
            createdBy: CKRecord.Reference(recordID: parent.id, action: .none),
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: templateRecordName, zoneID: family.id.zoneID)
        )
        await cache.upsertQuestTemplate(template)
        let quest = Quest(
            template: CKRecord.Reference(recordID: template.id, action: .none),
            assignee: CKRecord.Reference(recordID: hero.id, action: .none),
            goldReward: 5,
            xpReward: 10,
            scheduleType: .weeklyFlexible,
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: weekOf,
            createdBy: CKRecord.Reference(recordID: parent.id, action: .none),
            family: CKRecord.Reference(recordID: family.id, action: .none),
            name: "Quest",
            id: CKRecord.ID(recordName: recordName, zoneID: family.id.zoneID)
        )
        await cache.upsertQuest(quest)
    }

    @Test
    func `sweep defers when cache stale and cloud kit throws`() async throws {
        let scaffold = try makeScaffold()
        let ck = scaffold.cloudKit
        let cache = scaffold.cache
        let questService = scaffold.questService
        let family = scaffold.family
        let parent = scaffold.parent
        let hero = scaffold.hero
        let cal = Calendar.iso8601UTC
        let now = try #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 12)))
        let currentWeek = WeekMath.startOfWeek(for: now, payoutDay: .sunday)
        let pastWeek = try #require(cal.date(byAdding: .day, value: -7, to: currentWeek))

        await seedQuest(cache, family: family, hero: hero, parent: parent, weekOf: pastWeek, recordName: "past-quest-defer")
        cache.markCacheFresh(familyRecordName: family.id.recordName, type: .quest)

        // Paid period exists in cache would allow sweep, but we force the
        // stale-cache path by invalidating freshness so the service must query CloudKit.
        var paid = AllowancePeriod(
            weekOf: pastWeek,
            profile: CKRecord.Reference(recordID: hero.id, action: .none),
            questsTotal: 1,
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: "period-defer", zoneID: family.id.zoneID)
        )
        paid.status = .paid
        paid.totalEarned = 5
        paid.paidAmount = 5
        paid.paidDate = now
        // Do NOT insert into cache — force CloudKit query path.
        // Ensure freshness is absent so isCacheAuthoritative == false.
        cache.invalidateFreshness(familyRecordName: family.id.recordName, type: .allowancePeriod)
        ck.fetchError = CloudKitServiceError.networkUnavailable

        let swept = try await questService.sweepExpiredQuests(family: family, currentWeekOf: currentWeek)

        #expect(swept.isEmpty, "Sweep must defer when cache is stale and CloudKit query throws — no quests deactivated")
        let cached = cache.fetchQuests(family: family.id.recordName).first { $0.recordName == "past-quest-defer" }
        #expect(cached?.isActive == true, "Deferred sweep must leave past quest active")
    }

    @Test
    func `sweep deactivates when query succeeds`() async throws {
        let scaffold = try makeScaffold()
        let ck = scaffold.cloudKit
        let cache = scaffold.cache
        let questService = scaffold.questService
        let family = scaffold.family
        let parent = scaffold.parent
        let hero = scaffold.hero
        let zoneID = scaffold.zoneID
        let cal = Calendar.iso8601UTC
        let now = try #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 12)))
        let currentWeek = WeekMath.startOfWeek(for: now, payoutDay: .sunday)
        let pastWeek = try #require(cal.date(byAdding: .day, value: -7, to: currentWeek))

        await seedQuest(cache, family: family, hero: hero, parent: parent, weekOf: pastWeek, recordName: "past-quest-active")
        cache.markCacheFresh(familyRecordName: family.id.recordName, type: .quest)

        // Stale cache path — paid period lives only in CloudKit mock, query succeeds.
        cache.invalidateFreshness(familyRecordName: family.id.recordName, type: .allowancePeriod)
        var paid = AllowancePeriod(
            weekOf: pastWeek,
            profile: CKRecord.Reference(recordID: hero.id, action: .none),
            questsTotal: 1,
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: "period-success", zoneID: zoneID)
        )
        paid.status = .paid
        paid.totalEarned = 5
        paid.paidAmount = 5
        paid.paidDate = now
        ck.seedMockRecords([paid])
        ck.fetchError = nil

        let swept = try await questService.sweepExpiredQuests(family: family, currentWeekOf: currentWeek)

        #expect(swept.count == 1, "Sweep must deactivate exactly one expired quest when CloudKit query succeeds")
        #expect(swept.first?.active == false)
        let cached = cache.fetchQuests(family: family.id.recordName).first { $0.recordName == "past-quest-active" }
        #expect(cached?.isActive == false, "Past quest must be deactivated after successful sweep")
    }
}
