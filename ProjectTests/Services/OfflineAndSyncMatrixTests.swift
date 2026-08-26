//
//  OfflineAndSyncMatrixTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/13/26.
//

import CloudKit
import Foundation
@testable import LootList
import XCTest

@MainActor
final class OfflineAndSyncMatrixTests: XCTestCase {
    var appState: AppState!
    var cloudKit: MockCloudKitService!
    var cacheService: CacheService!
    var questService: QuestService!
    var family: Family!
    var hero: Profile!

    override func setUp() async throws {
        try await super.setUp()
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        cloudKit = MockCloudKitService()
        cloudKit.activeFamilyZoneID = zoneID
        cacheService = try CacheService(inMemory: true)
        appState = AppState()
        appState.cacheService = cacheService

        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none)
        let userID = CKRecord.ID(recordName: "user1", zoneID: zoneID)

        hero = Profile(
            displayName: "Hero",
            avatarClass: .mage,
            avatarPresetID: "mage_01",
            role: .hero,
            iCloudUserID: userID,
            family: familyRef,
            id: CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        )

        family = Family(
            name: "Matrix Family",
            createdBy: hero.id,
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )

        appState.family = family
        appState.currentProfile = hero
        appState.familyZoneID = zoneID

        let xpService = XPService(cloudKit: cloudKit, cacheService: cacheService, appState: appState)
        questService = QuestService(
            cloudKit: cloudKit,
            xpService: xpService,
            cacheService: cacheService,
            appState: appState
        )
    }

    func testFreshEmptyCacheReturnsZeroItemsWithoutCloudKitFetch() async throws {
        cacheService.markCacheFresh(familyRecordName: "fam1", type: .quest)
        cloudKit.fetchError = NSError(domain: "test", code: -1, userInfo: nil)

        let quests = try await questService.fetchActiveQuests(profile: hero, weekOf: Date())
        XCTAssertTrue(quests.isEmpty)
    }

    func testCacheHitReturnsLocalModels() async throws {
        let zoneID = try XCTUnwrap(appState.familyZoneID)
        let templateRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "t1", zoneID: zoneID), action: .none)
        let heroRef = CKRecord.Reference(recordID: hero.id, action: .none)
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let weekStart = WeekMath.startOfWeek(for: Date(), payoutDay: .sunday)

        let quest = Quest(
            template: templateRef,
            assignee: heroRef,
            goldReward: 10,
            xpReward: 10,
            scheduleType: .weeklyFlexible,
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: weekStart,
            createdBy: heroRef,
            family: familyRef,
            name: "Clean Room",
            descriptionText: "Clean it",
            id: CKRecord.ID(recordName: "q1", zoneID: zoneID)
        )

        await cacheService.upsertQuest(quest)
        cacheService.markCacheFresh(familyRecordName: "fam1", type: .quest)
        cloudKit.fetchError = NSError(domain: "test", code: -1, userInfo: nil)

        let quests = try await questService.fetchActiveQuests(profile: hero, weekOf: Date())
        XCTAssertEqual(quests.count, 1)
        XCTAssertEqual(quests.first?.id.recordName, quest.id.recordName)
    }

    func testStaleCacheTriggersCloudKitFetch() async throws {
        // Cache is NOT fresh
        cacheService.invalidateAllFreshness()

        let zoneID = try XCTUnwrap(appState.familyZoneID)
        let templateRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "t1", zoneID: zoneID), action: .none)
        let heroRef = CKRecord.Reference(recordID: hero.id, action: .none)
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let weekStart = WeekMath.startOfWeek(for: Date(), payoutDay: .sunday)

        let cloudQuest = Quest(
            template: templateRef,
            assignee: heroRef,
            goldReward: 15,
            xpReward: 30,
            scheduleType: .weeklyFlexible,
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: weekStart,
            createdBy: heroRef,
            family: familyRef,
            name: "Mow Lawn",
            descriptionText: "Mow the lawn",
            id: CKRecord.ID(recordName: "q2", zoneID: zoneID)
        )

        cloudKit.seedMockRecords([cloudQuest])

        let quests = try await questService.fetchActiveQuests(profile: hero, weekOf: Date())
        XCTAssertEqual(quests.count, 1)
        XCTAssertEqual(quests.first?.name, "Mow Lawn")
    }

    func testAchievementServiceFreshEmptyCacheReturnsZeroItemsOffline() async throws {
        let achievementService = AchievementService(cloudKit: cloudKit, cacheService: cacheService, appState: appState)
        cacheService.markCacheFresh(familyRecordName: "fam1", type: .achievement)
        cacheService.markCacheFresh(familyRecordName: "fam1", type: .profileAchievement)

        // Inject network error to prove we do not hit CloudKit
        cloudKit.fetchError = NSError(domain: "test", code: -1, userInfo: nil)

        let defs = try await achievementService.fetchAllDefinitions(family: family)
        let earned = try await achievementService.fetchEarned(profile: hero)
        XCTAssertTrue(defs.isEmpty)
        XCTAssertTrue(earned.isEmpty)
    }
}
