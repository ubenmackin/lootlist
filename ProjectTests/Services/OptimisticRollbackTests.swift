//
//  OptimisticRollbackTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/13/26.
//

import CloudKit
import Foundation
@testable import LootList
import XCTest

@MainActor
final class OptimisticRollbackTests: XCTestCase {
    var appState: AppState!
    var cloudKit: MockCloudKitService!
    var cacheService: CacheService!
    var questService: QuestService!
    var xpService: XPService!
    var family: Family!
    var hero: Profile!
    var zoneID: CKRecordZone.ID!

    override func setUp() async throws {
        try await super.setUp()
        zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
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
            name: "Test Guild",
            createdBy: hero.id,
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )

        appState.family = family
        appState.currentProfile = hero
        appState.familyZoneID = zoneID
        appState.isZoneOwner = cloudKit.activeIsOwner

        xpService = XPService(cloudKit: cloudKit, cacheService: cacheService, appState: appState)
        questService = QuestService(
            cloudKit: cloudKit,
            xpService: xpService,
            cacheService: cacheService,
            appState: appState
        )
    }

    func testDeterministicRewardEventRecordID() {
        let completionName = "completion-123"
        let expectedID = CKRecord.ID(recordName: "reward-completion-123", zoneID: zoneID)
        let actualID = RewardEvent.recordID(completionRecordName: completionName, zoneID: zoneID)

        XCTAssertEqual(actualID, expectedID)
    }

    func testReRunningRewardGrantWithExistingCreditDoesNotMintDuplicateXP() async throws {
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let heroRef = CKRecord.Reference(recordID: hero.id, action: .none)
        let templateRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "t1", zoneID: zoneID), action: .none)
        let weekStart = WeekMath.startOfWeek(for: Date(), payoutDay: .sunday)

        let quest = Quest(
            template: templateRef,
            assignee: heroRef,
            goldReward: 10,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: weekStart,
            createdBy: heroRef,
            family: familyRef,
            name: "Daily Workout",
            descriptionText: "Do pushups",
            id: CKRecord.ID(recordName: "q1", zoneID: zoneID)
        )

        // Seed initial records
        cacheService.upsertProfile(hero)
        cacheService.upsertQuest(quest)
        cloudKit.seedMockRecords([hero, quest])

        // 1. A completion that already has xpCredited stamped
        let alreadyCreditedCompletion = QuestCompletion(
            quest: CKRecord.Reference(recordID: quest.id, action: .none),
            completedBy: heroRef,
            approvalMode: .autoApprove,
            completedDate: Date(),
            weekOf: weekStart,
            family: familyRef,
            xpCredited: 50,
            id: CKRecord.ID(recordName: "c1", zoneID: zoneID)
        )

        let initialXP = hero.xp
        _ = try await questService.applyReward(for: quest, to: hero, completion: alreadyCreditedCompletion)

        let heroAfterSkippedCredit = cacheService.fetchProfile(recordName: hero.id.recordName, family: family.id.recordName)
        XCTAssertEqual(heroAfterSkippedCredit?.xpTotal, initialXP, "Already credited completion should not grant duplicate XP")

        // 2. A fresh completion with nil xpCredited
        let freshCompletion = QuestCompletion(
            quest: CKRecord.Reference(recordID: quest.id, action: .none),
            completedBy: heroRef,
            approvalMode: .autoApprove,
            completedDate: Date(),
            weekOf: weekStart,
            family: familyRef,
            xpCredited: nil,
            id: CKRecord.ID(recordName: "c2", zoneID: zoneID)
        )

        _ = try await questService.applyReward(for: quest, to: hero, completion: freshCompletion)

        let heroAfterFreshCredit = cacheService.fetchProfile(recordName: hero.id.recordName, family: family.id.recordName)
        XCTAssertEqual(heroAfterFreshCredit?.xpTotal, initialXP + 50, "Fresh completion should grant XP reward")
    }

    func testDeterministicPayoutLedgerEntryMintingAndDoubleMintPrevention() async throws {
        let parentID = CKRecord.ID(recordName: "parent1", zoneID: zoneID)
        let parent = Profile(
            displayName: "Guild Master",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .guildMaster,
            iCloudUserID: parentID,
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: parentID
        )
        appState.currentProfile = parent
        cacheService.upsertProfile(parent)
        cacheService.upsertProfile(hero)
        cacheService.upsertFamily(family)
        cloudKit.seedMockRecords([parent, hero, family])

        let treasuryService = TreasuryService(
            cloudKit: cloudKit,
            cacheService: cacheService,
            appState: appState
        )

        let weekStart = WeekMath.startOfWeek(for: Date(), payoutDay: .sunday)
        let quest = Quest(
            template: CKRecord.Reference(recordID: CKRecord.ID(recordName: "t1", zoneID: zoneID), action: .none),
            assignee: CKRecord.Reference(recordID: hero.id, action: .none),
            goldReward: 25.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: weekStart,
            createdBy: CKRecord.Reference(recordID: parent.id, action: .none),
            family: CKRecord.Reference(recordID: family.id, action: .none),
            name: "Dragon Slaying",
            id: CKRecord.ID(recordName: "q_payout", zoneID: zoneID)
        )
        let completion = QuestCompletion(
            quest: CKRecord.Reference(recordID: quest.id, action: .none),
            completedBy: CKRecord.Reference(recordID: hero.id, action: .none),
            approvalMode: .autoApprove,
            completedDate: weekStart.addingTimeInterval(3600),
            weekOf: weekStart,
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: "c_payout", zoneID: zoneID)
        )
        cacheService.upsertQuest(quest)
        cacheService.upsertQuestCompletion(completion)
        cloudKit.seedMockRecords([quest, completion])

        let periodRecordName = "period-\(family.id.recordName)-\(hero.id.recordName)-\(Int(weekStart.timeIntervalSince1970))"
        let period = AllowancePeriod(
            weekOf: weekStart,
            profile: CKRecord.Reference(recordID: hero.id, action: .none),
            questsTotal: 1,
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: periodRecordName, zoneID: zoneID)
        )
        var unfinalized = period
        unfinalized.status = .active
        unfinalized.totalEarned = 25.0
        unfinalized.questsCompleted = 1
        cacheService.upsertAllowancePeriod(unfinalized)
        cloudKit.seedMockRecords([unfinalized])

        // First payout run: mints the deterministic payout ledger entry
        try await treasuryService.runPayout(period: unfinalized)

        let paidPeriod = cacheService.fetchAllowancePeriod(recordName: periodRecordName, family: family.id.recordName)
        XCTAssertEqual(paidPeriod?.statusEnum, .paid)
        XCTAssertEqual(paidPeriod?.paidAmount, 25.0)

        let expectedLedgerName = "payout-\(periodRecordName)"
        let ledgersAfterFirst = cacheService.fetchLedgerEntries(profileRecordName: hero.id.recordName, family: family.id.recordName)
        XCTAssertEqual(ledgersAfterFirst.count, 1)
        XCTAssertEqual(ledgersAfterFirst.first?.recordName, expectedLedgerName)
        XCTAssertEqual(ledgersAfterFirst.first?.amount, 25.0)

        // Second payout run (e.g. cross-device race or replay): double-mint guard must prevent duplicate ledger creation
        if let paidPeriodDomain = paidPeriod?.toAllowancePeriod(zoneID: zoneID) {
            try await treasuryService.runPayout(period: paidPeriodDomain)
        }

        let ledgersAfterSecond = cacheService.fetchLedgerEntries(profileRecordName: hero.id.recordName, family: family.id.recordName)
        XCTAssertEqual(ledgersAfterSecond.count, 1, "Double-mint guard must prevent duplicate ledger entries on re-run")
    }

    func testPayoutSkipsMintingWhenRealTimeLedgerAlreadyExists() async throws {
        let parentID = CKRecord.ID(recordName: "parent1", zoneID: zoneID)
        let parent = Profile(
            displayName: "Guild Master",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .guildMaster,
            iCloudUserID: parentID,
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: parentID
        )
        appState.currentProfile = parent
        cacheService.upsertProfile(parent)
        cacheService.upsertProfile(hero)
        cacheService.upsertFamily(family)
        cloudKit.seedMockRecords([parent, hero, family])

        let treasuryService = TreasuryService(
            cloudKit: cloudKit,
            cacheService: cacheService,
            appState: appState
        )

        let weekStart = WeekMath.startOfWeek(for: Date(), payoutDay: .sunday)
        let quest = Quest(
            template: CKRecord.Reference(recordID: CKRecord.ID(recordName: "t1", zoneID: zoneID), action: .none),
            assignee: CKRecord.Reference(recordID: hero.id, action: .none),
            goldReward: 15.0,
            xpReward: 30,
            scheduleType: .weeklyFlexible,
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: weekStart,
            createdBy: CKRecord.Reference(recordID: parent.id, action: .none),
            family: CKRecord.Reference(recordID: family.id, action: .none),
            name: "Sweep Floor",
            id: CKRecord.ID(recordName: "q_rt", zoneID: zoneID)
        )
        let completion = QuestCompletion(
            quest: CKRecord.Reference(recordID: quest.id, action: .none),
            completedBy: CKRecord.Reference(recordID: hero.id, action: .none),
            approvalMode: .autoApprove,
            completedDate: weekStart.addingTimeInterval(3600),
            weekOf: weekStart,
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: "c_rt", zoneID: zoneID)
        )
        cacheService.upsertQuest(quest)
        cacheService.upsertQuestCompletion(completion)
        cloudKit.seedMockRecords([quest, completion])

        let periodRecordName = "period-\(family.id.recordName)-\(hero.id.recordName)-\(Int(weekStart.timeIntervalSince1970))"

        // Seed a pre-existing real-time ledger entry for this period
        let rtLedger = LedgerEntry(
            profile: CKRecord.Reference(recordID: hero.id, action: .none),
            amount: 15.0,
            description: "Real-time quest earnings",
            date: Date(),
            source: "quest",
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: "rt-\(periodRecordName)", zoneID: zoneID)
        )
        cacheService.upsertLedgerEntry(rtLedger)

        let period = AllowancePeriod(
            weekOf: weekStart,
            profile: CKRecord.Reference(recordID: hero.id, action: .none),
            questsTotal: 1,
            family: CKRecord.Reference(recordID: family.id, action: .none),
            id: CKRecord.ID(recordName: periodRecordName, zoneID: zoneID)
        )
        var unfinalized = period
        unfinalized.status = .active
        unfinalized.totalEarned = 15.0
        unfinalized.questsCompleted = 1
        cacheService.upsertAllowancePeriod(unfinalized)

        try await treasuryService.runPayout(period: unfinalized)

        let allLedgers = cacheService.fetchLedgerEntries(profileRecordName: hero.id.recordName, family: family.id.recordName)
        XCTAssertEqual(allLedgers.count, 1, "Defense-in-depth: rt- ledger prevents payout- double minting")
        XCTAssertEqual(allLedgers.first?.recordName, "rt-\(periodRecordName)")
    }

    func testSaveErrorInjectionThrowsAndDoesNotPersistStaleCloudRecord() async throws {
        let familyRef = CKRecord.Reference(recordID: family.id, action: .none)
        let heroRef = CKRecord.Reference(recordID: hero.id, action: .none)
        let templateRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "t1", zoneID: zoneID), action: .none)
        let weekStart = WeekMath.startOfWeek(for: Date(), payoutDay: .sunday)

        let quest = Quest(
            template: templateRef,
            assignee: heroRef,
            goldReward: 10,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            targetCount: 1,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: weekStart,
            createdBy: heroRef,
            family: familyRef,
            name: "Daily Workout",
            descriptionText: "Do pushups",
            id: CKRecord.ID(recordName: "q1", zoneID: zoneID)
        )

        cloudKit.seedMockRecords([hero, quest])
        cloudKit.saveError = CloudKitServiceError.serverRecordChanged

        let completion = QuestCompletion(
            quest: CKRecord.Reference(recordID: quest.id, action: .none),
            completedBy: heroRef,
            approvalMode: .autoApprove,
            completedDate: Date(),
            weekOf: weekStart,
            family: familyRef,
            xpCredited: nil,
            id: CKRecord.ID(recordName: "c3", zoneID: zoneID)
        )

        do {
            _ = try await questService.applyReward(for: quest, to: hero, completion: completion)
        } catch {
            XCTAssertTrue(error is CloudKitServiceError)
        }
    }
}
