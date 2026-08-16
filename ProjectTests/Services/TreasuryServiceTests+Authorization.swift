//
//  TreasuryServiceTests+Authorization.swift
//  LootList
//
//  Created by Ben Mackin on 8/6/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

extension TreasuryServiceTests {
    // MARK: - Service-layer authorization (parent-only payout finalization)

    @Test
    func `runPayout throws unauthorized when acting profile is a hero`() async {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService(zoneID: zoneID)
        let appState = AppState()
        let treasury = TreasuryService(cloudKit: cloudKit, appState: appState)

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
        appState.currentProfile = hero

        let period = AllowancePeriod(
            weekOf: WeekMath.mondayOfWeek(for: Date()),
            profile: CKRecord.Reference(recordID: heroID, action: .none),
            questsTotal: 1,
            family: familyRef
        )

        await #expect(throws: FamilyServiceError.unauthorized) {
            try await treasury.runPayout(period: period)
        }
    }

    @Test
    func `runPayout throws unauthorized when no acting profile exists`() async {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService(zoneID: zoneID)
        // No appState wired: the acting profile is unknowable, so the payout
        // must not be finalizable.
        let treasury = TreasuryService(cloudKit: cloudKit)

        let familyRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
        )
        let heroID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        let period = AllowancePeriod(
            weekOf: WeekMath.mondayOfWeek(for: Date()),
            profile: CKRecord.Reference(recordID: heroID, action: .none),
            questsTotal: 1,
            family: familyRef
        )

        await #expect(throws: FamilyServiceError.unauthorized) {
            try await treasury.runPayout(period: period)
        }
    }

    @Test
    func `runPayout succeeds when acting profile is a parent`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService(zoneID: zoneID)
        let appState = AppState()
        let cache = try CacheService(inMemory: true)
        let treasury = TreasuryService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let familyRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
        )
        let heroID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        let guildMaster = Profile(
            displayName: "Guild Master",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .guildMaster,
            iCloudUserID: CKRecord.ID(recordName: "gm1", zoneID: zoneID),
            family: familyRef,
            id: CKRecord.ID(recordName: "gm1", zoneID: zoneID)
        )
        appState.currentProfile = guildMaster

        let period = AllowancePeriod(
            weekOf: WeekMath.mondayOfWeek(for: Date()),
            profile: CKRecord.Reference(recordID: heroID, action: .none),
            questsTotal: 1,
            family: familyRef,
            id: CKRecord.ID(recordName: "period1", zoneID: zoneID)
        )
        var settled = period
        settled.totalEarned = 25.0
        settled.questsCompleted = 1
        try await treasury.runPayout(period: settled)

        let cached = try #require(cache.fetchAllowancePeriods(profileRecordName: heroID.recordName, family: "fam1").first)
        #expect(cached.status == PayoutStatus.paid.rawValue)
        #expect(cached.paidAmount == 25.0)
    }

    // MARK: - Mixed identity/parent guards on internal settlement helpers

    @Test
    func `processRealTimeSettlement returns nil when acting profile does not match`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService(zoneID: zoneID)
        let appState = AppState()
        let treasury = TreasuryService(cloudKit: cloudKit, appState: appState)

        let familyRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
        )
        let otherHeroID = CKRecord.ID(recordName: "other", zoneID: zoneID)
        let otherHero = Profile(
            displayName: "Other Hero",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .hero,
            iCloudUserID: otherHeroID,
            family: familyRef,
            id: otherHeroID
        )
        appState.currentProfile = otherHero

        // Target has .realTime policy so the policy guard would pass — only
        // the identity mismatch can produce the nil result.
        let targetHeroID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        let targetHero = Profile(
            displayName: "Target Hero",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .hero,
            iCloudUserID: targetHeroID,
            family: familyRef,
            payoutPolicy: .realTime,
            id: targetHeroID
        )
        let family = Family(
            name: "Test Guild",
            createdBy: CKRecord.ID(recordName: "parent1", zoneID: zoneID),
            payoutDay: .sunday,
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )

        let result = try await treasury.processRealTimeSettlement(profile: targetHero, family: family)
        #expect(result == nil, "Identity mismatch must short-circuit before any internal flow")
    }

    @Test
    func `processRealTimeSettlement settles when a parent acts on a real time hero`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService(zoneID: zoneID)
        let appState = AppState()
        let treasury = TreasuryService(cloudKit: cloudKit, appState: appState)

        let familyRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
        )
        let guildMasterID = CKRecord.ID(recordName: "gm1", zoneID: zoneID)
        let guildMaster = Profile(
            displayName: "Guild Master",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .guildMaster,
            iCloudUserID: guildMasterID,
            family: familyRef,
            id: guildMasterID
        )
        appState.currentProfile = guildMaster

        let targetHeroID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        let targetHero = Profile(
            displayName: "Target Hero",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .hero,
            iCloudUserID: targetHeroID,
            family: familyRef,
            payoutPolicy: .realTime,
            id: targetHeroID
        )
        let family = Family(
            name: "Test Guild",
            createdBy: guildMasterID,
            payoutDay: .sunday,
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
        let monday = WeekMath.mondayOfWeek(for: Date())
        let questID = CKRecord.ID(recordName: "quest1", zoneID: zoneID)
        let templateRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none
        )
        let quest = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(recordID: targetHeroID, action: .none),
            goldReward: 25.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: monday,
            createdBy: familyRef,
            family: familyRef,
            name: "Verified Quest",
            id: questID
        )
        let completion = QuestCompletion(
            quest: CKRecord.Reference(recordID: questID, action: .none),
            completedBy: CKRecord.Reference(recordID: targetHeroID, action: .none),
            approvalMode: .autoApprove,
            weekOf: monday,
            family: familyRef
        )
        cloudKit.seedMockRecords([targetHero, family, quest, completion])

        // Parent-verified quests settle on the hero's behalf: the acting
        // profile is the parent, not the hero, and the settlement must
        // proceed — the identity-only guard previously dropped it, leaving
        // the hero's wallet un-credited.
        let result = try await treasury.processRealTimeSettlement(
            profile: targetHero,
            family: family,
            date: monday
        )
        let period = try #require(result, "A parent acting on a real-time hero must not be dropped")
        #expect(period.profile.recordID == targetHero.id, "Settlement must target the hero's period")
        #expect(period.totalEarned == 25.0, "Parent-verified gold must settle on the hero's period")
        #expect(period.paidAmount == 25.0)
    }

    @Test
    func `getOrCreateAllowancePeriod throws unauthorized for non-parent mismatched profile`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService(zoneID: zoneID)
        let appState = AppState()
        let treasury = TreasuryService(cloudKit: cloudKit, appState: appState)

        let familyRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
        )
        let otherHeroID = CKRecord.ID(recordName: "other", zoneID: zoneID)
        let otherHero = Profile(
            displayName: "Other Hero",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .hero,
            iCloudUserID: otherHeroID,
            family: familyRef,
            id: otherHeroID
        )
        appState.currentProfile = otherHero

        let targetHeroID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        let targetHero = Profile(
            displayName: "Target Hero",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .hero,
            iCloudUserID: targetHeroID,
            family: familyRef,
            id: targetHeroID
        )
        let family = Family(
            name: "Test Guild",
            createdBy: CKRecord.ID(recordName: "parent1", zoneID: zoneID),
            payoutDay: .sunday,
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )

        await #expect(throws: FamilyServiceError.unauthorized) {
            try await treasury.getOrCreateAllowancePeriod(
                profile: targetHero,
                weekOf: WeekMath.mondayOfWeek(for: Date()),
                family: family
            )
        }
    }

    @Test
    func `updateAllowance throws unauthorized for non-parent mismatched profile`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService(zoneID: zoneID)
        let appState = AppState()
        let treasury = TreasuryService(cloudKit: cloudKit, appState: appState)

        let familyRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "fam1", zoneID: zoneID), action: .none
        )
        let otherHeroID = CKRecord.ID(recordName: "other", zoneID: zoneID)
        let otherHero = Profile(
            displayName: "Other Hero",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .hero,
            iCloudUserID: otherHeroID,
            family: familyRef,
            id: otherHeroID
        )
        appState.currentProfile = otherHero

        let targetHeroID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        let period = AllowancePeriod(
            weekOf: WeekMath.mondayOfWeek(for: Date()),
            profile: CKRecord.Reference(recordID: targetHeroID, action: .none),
            questsTotal: 1,
            family: familyRef
        )

        await #expect(throws: FamilyServiceError.unauthorized) {
            try await treasury.updateAllowance(period: period,
                                               totalEarned: 25.0,
                                               questsCompleted: 1)
        }
    }

    // MARK: - Triple-guard scenario (processRealTimeSettlement → getOrCreateAllowancePeriod → updateAllowance)

    @Test
    func `processRealTimeSettlement succeeds end-to-end for hero self-settlement (triple guard)`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let treasury = TreasuryService(cloudKit: cloudKit, cacheService: cache, appState: appState)

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
            payoutPolicy: .realTime,
            id: heroID
        )
        let family = Family(
            name: "Test Guild",
            createdBy: CKRecord.ID(recordName: "parent1", zoneID: zoneID),
            payoutDay: .sunday,
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
        cloudKit.seedMockRecords([hero, family])

        let monday = WeekMath.mondayOfWeek(for: Date())
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
            name: "Settle Quest",
            id: questID
        )
        let completion = QuestCompletion(
            quest: CKRecord.Reference(recordID: questID, action: .none),
            completedBy: CKRecord.Reference(recordID: heroID, action: .none),
            approvalMode: .autoApprove,
            weekOf: monday,
            family: familyRef
        )
        cache.upsertQuest(quest)
        cache.upsertQuestCompletions([completion])
        cache.markCacheFresh(familyRecordName: "fam1", type: .questCompletion)

        // Hero self-settlement: the acting profile matches the target.
        appState.currentProfile = hero

        let settled = try await treasury.processRealTimeSettlement(profile: hero,
                                                                   family: family,
                                                                   date: monday)
        let period = try #require(settled, "Triple guard must let self-settlement reach a period")
        #expect(period.totalEarned == 25.0, "Settlement must propagate hero's earnings")
        #expect(period.questsCompleted == 1)
        #expect(period.paidAmount == 25.0)
    }

    @Test
    func `getOrCreateAllowancePeriod allows parent override`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let treasury = TreasuryService(cloudKit: cloudKit, cacheService: cache, appState: appState)

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
        let guildMasterID = CKRecord.ID(recordName: "gm1", zoneID: zoneID)
        let guildMaster = Profile(
            displayName: "Guild Master",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .guildMaster,
            iCloudUserID: guildMasterID,
            family: familyRef,
            id: guildMasterID
        )
        let family = Family(
            name: "Test Guild",
            createdBy: guildMasterID,
            payoutDay: .sunday,
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
        cloudKit.seedMockRecords([hero, family])

        // Parent operates on the hero's allowance period.
        appState.currentProfile = guildMaster

        let period = try await treasury.getOrCreateAllowancePeriod(
            profile: hero,
            weekOf: WeekMath.mondayOfWeek(for: Date()),
            family: family
        )
        #expect(period.profile.recordID == hero.id, "Period must be the hero's")
    }

    @Test
    func `updateAllowance allows parent override`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = MockCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let treasury = TreasuryService(cloudKit: cloudKit, cacheService: cache, appState: appState)

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
        let guildMasterID = CKRecord.ID(recordName: "gm1", zoneID: zoneID)
        let guildMaster = Profile(
            displayName: "Guild Master",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .guildMaster,
            iCloudUserID: guildMasterID,
            family: familyRef,
            id: guildMasterID
        )
        let family = Family(
            name: "Test Guild",
            createdBy: guildMasterID,
            payoutDay: .sunday,
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )
        cloudKit.seedMockRecords([hero, family])

        let period = AllowancePeriod(
            weekOf: WeekMath.mondayOfWeek(for: Date()),
            profile: CKRecord.Reference(recordID: heroID, action: .none),
            questsTotal: 1,
            family: familyRef,
            id: CKRecord.ID(recordName: "period1", zoneID: zoneID)
        )

        // Parent operating on the hero's allowance period.
        appState.currentProfile = guildMaster

        let updated = try await treasury.updateAllowance(period: period,
                                                         totalEarned: 50.0,
                                                         questsCompleted: 1)
        #expect(updated.totalEarned == 50.0)
        #expect(updated.questsCompleted == 1)
    }

    // MARK: - Settlement path reads profile/family cache-first

    @Test
    func `updateAllowance resolves profile and family from cache with zero CloudKit reads`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        // Reads throw networkUnavailable, so any fallthrough to a CloudKit
        // fetch/query would both throw AND bump readCallCount above 0.
        let cloudKit = NetworkCountingCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let appState = AppState()
        let treasury = TreasuryService(cloudKit: cloudKit, cacheService: cache, appState: appState)

        let familyID = CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        let familyRef = CKRecord.Reference(recordID: familyID, action: .none)
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
        let guildMasterID = CKRecord.ID(recordName: "gm1", zoneID: zoneID)
        let guildMaster = Profile(
            displayName: "Guild Master",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .guildMaster,
            iCloudUserID: guildMasterID,
            family: familyRef,
            id: guildMasterID
        )
        let family = Family(
            name: "Test Guild",
            createdBy: guildMasterID,
            payoutDay: .sunday,
            id: familyID
        )

        let monday = WeekMath.mondayOfWeek(for: Date())
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
            name: "Cached Quest",
            id: questID
        )
        let completion = QuestCompletion(
            quest: CKRecord.Reference(recordID: questID, action: .none),
            completedBy: CKRecord.Reference(recordID: heroID, action: .none),
            approvalMode: .autoApprove,
            weekOf: monday,
            family: familyRef
        )
        // A bonus ledger entry in the week so the ledgerEntries cache gate is
        // non-empty (the read-first contract returns the cache only when fresh
        // AND non-empty) and the breakdown's bonusGold is cache-sourced.
        let bonus = LedgerEntry(
            profile: CKRecord.Reference(recordID: heroID, action: .none),
            amount: 5.0,
            description: "Bonus",
            date: monday,
            source: "manual",
            family: familyRef
        )

        // Seed the cache (NOT CloudKit's mock store) with every record the
        // settlement path reads, and stamp each type fresh. A completed sync
        // pass would have produced exactly this state.
        cache.upsertProfile(hero)
        cache.upsertProfile(guildMaster)
        cache.upsertFamily(family)
        cache.upsertQuest(quest)
        cache.upsertQuestCompletions([completion])
        cache.upsertLedgerEntry(bonus)
        cache.markCacheFresh(familyRecordName: familyID.recordName, type: .profile)
        cache.markCacheFresh(familyRecordName: familyID.recordName, type: .family)
        cache.markCacheFresh(familyRecordName: familyID.recordName, type: .quest)
        cache.markCacheFresh(familyRecordName: familyID.recordName, type: .questCompletion)
        cache.markCacheFresh(familyRecordName: familyID.recordName, type: .ledgerEntry)

        let period = AllowancePeriod(
            weekOf: monday,
            profile: CKRecord.Reference(recordID: heroID, action: .none),
            questsTotal: 1,
            family: familyRef,
            id: CKRecord.ID(recordName: "period1", zoneID: zoneID)
        )

        // Parent operating on the hero's allowance period (mirrors the
        // existing `updateAllowance allows parent override` guard).
        appState.currentProfile = guildMaster

        // Pass nil for the breakdown-derived totals so the result MUST come
        // from weeklyBreakdown — which only runs when resolveProfile /
        // resolveFamily succeed via the cache.
        let updated = try await treasury.updateAllowance(period: period)

        // No Profile/Family (or any other) CloudKit read issued — the
        // settlement read path served everything from the cache.
        #expect(
            cloudKit.readCallCount == 0,
            "updateAllowance must resolve profile + family from cache when fresh; no CloudKit fetch"
        )

        // Hoisted straight from cache-sourced weeklyBreakdown: 25.0 (quest
        // gold) + 5.0 (bonus ledger) = 30.0. On the pre-fix path the
        // Profile/Family CK fetch throws networkUnavailable, weeklyBreakdown
        // is skipped (try? swallows), and totalEarned stays at the period's
        // creation-time 0 — so this asserts the cache-sourced profile
        // actually flowed through the breakdown.
        #expect(updated.totalEarned == 30.0)
        #expect(updated.questsCompleted == 1)
    }

    @Test
    func `weeklyBreakdown serves allOrNothing assignedQuests from cache with zero CloudKit reads`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        // The read-mock throws networkUnavailable for every fetch/query AND
        // bumps readCallCount, so any fallthrough off the cache-hit path both
        // throws AND fails the readCallCount == 0 gate.
        let cloudKit = NetworkCountingCloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let treasury = TreasuryService(cloudKit: cloudKit, cacheService: cache)

        let familyID = CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        let familyRef = CKRecord.Reference(recordID: familyID, action: .none)
        let heroID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        // allOrNothing policy exercises the fetchAssignedQuests branch of
        // weeklyBreakdown, which routes assigned-quest reads through the
        // cache-first gate.
        let hero = Profile(
            displayName: "Hero",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .hero,
            iCloudUserID: heroID,
            family: familyRef,
            payoutPolicy: .allOrNothing,
            id: heroID
        )
        let family = Family(
            name: "Test Guild",
            createdBy: CKRecord.ID(recordName: "parent1", zoneID: zoneID),
            payoutDay: .sunday,
            id: familyID
        )

        let monday = WeekMath.mondayOfWeek(for: Date())
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
            name: "Cached Quest",
            id: questID
        )
        let completion = QuestCompletion(
            quest: CKRecord.Reference(recordID: questID, action: .none),
            completedBy: CKRecord.Reference(recordID: heroID, action: .none),
            approvalMode: .autoApprove,
            weekOf: monday,
            family: familyRef
        )
        // A bonus ledger entry in the week so the ledgerEntries cache gate is
        // non-empty (the read-first contract returns the cache only when fresh
        // AND non-empty) — otherwise the empty ledger cache falls through to a
        // CloudKit query and the readCallCount == 0 gate fails.
        let bonus = LedgerEntry(
            profile: CKRecord.Reference(recordID: heroID, action: .none),
            amount: 7.0,
            description: "Bonus",
            date: monday,
            source: "manual",
            family: familyRef
        )

        // Seed the cache (NOT CloudKit) with every record weeklyBreakdown
        // touches — quests (assigned-quests lookup in the allOrNothing
        // branch + the gold-proration quest lookup), completions, and the
        // bonus ledger entry — and stamp each type fresh. A completed sync
        // pass would have produced exactly this state.
        cache.upsertProfile(hero)
        cache.upsertFamily(family)
        cache.upsertQuest(quest)
        cache.upsertQuestCompletions([completion])
        cache.upsertLedgerEntry(bonus)
        cache.markCacheFresh(familyRecordName: familyID.recordName, type: .profile)
        cache.markCacheFresh(familyRecordName: familyID.recordName, type: .family)
        cache.markCacheFresh(familyRecordName: familyID.recordName, type: .quest)
        cache.markCacheFresh(familyRecordName: familyID.recordName, type: .questCompletion)
        cache.markCacheFresh(familyRecordName: familyID.recordName, type: .ledgerEntry)

        let breakdown = try await treasury.weeklyBreakdown(profile: hero,
                                                           family: family,
                                                           weekOf: monday)

        // No CloudKit read issued for the breakdown path: assignedQuests in
        // the allOrNothing branch, quest logs, gold proration, and ledger
        // entries were all served from cache. If fetchAssignedQuests (or any
        // sibling read) fell through to CloudKit, the networkUnavailable
        // throw would rethrow out of weeklyBreakdown AND readCallCount would
        // be non-zero.
        #expect(
            cloudKit.readCallCount == 0,
            "weeklyBreakdown must serve assignedQuests (and every read) from cache when fresh; no CloudKit fetch/query"
        )

        // The cache-sourced result: one completed quest out of one assigned,
        // so allOrNothing does NOT zero the gold — 25.0 (quest) + 7.0
        // (bonus ledger) = 32.0 flows through.
        #expect(breakdown.goldFromQuests == 25.0)
        #expect(breakdown.questsCount == 1)
        #expect(breakdown.totalEarned == 32.0)
    }
}
