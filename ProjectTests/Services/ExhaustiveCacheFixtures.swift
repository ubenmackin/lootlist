//
//  ExhaustiveCacheFixtures.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

/// WHY single source: one edit covers all 13 types plus system-field asserts.
enum ExhaustiveCacheFixtures {
    static let expectedTypeCount = 13
    static let familyRecordName = "fam_exhaustive"

    static var fixedDate: Date {
        Date(timeIntervalSince1970: 1_750_000_000)
    }

    static var weekOf: Date {
        Date(timeIntervalSince1970: 1_749_950_000)
    }

    static func ref(_ name: String, zoneID: CKRecordZone.ID) -> CKRecord.Reference {
        CKRecord.Reference(recordID: id(name, zoneID: zoneID), action: .none)
    }

    static func id(_ name: String, zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    static var sharedZoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
    }

    static let sharedFamilyRecordName = "fam1"
    static let sharedHeroRecordName = "hero1"
    static let sharedParentRecordName = "parent1"

    /// WHY single source for TestZone/fam1 boilerplate duplicated across service tests.
    static func sharedFamilyRef(zoneID: CKRecordZone.ID, familyRecordName: String = sharedFamilyRecordName) -> CKRecord.Reference {
        ref(familyRecordName, zoneID: zoneID)
    }

    /// WHY owner anchor must match the mock's server-authenticated user.
    @MainActor
    static func sharedFamily(
        zoneID: CKRecordZone.ID,
        name: String = "Test Guild",
        creatorUserRecordName: String? = MockCloudKitService.mockUserRecordName,
        recordName: String = sharedFamilyRecordName,
        payoutPolicy: PayoutPolicy = .perQuest
    ) -> Family {
        Family(
            name: name,
            creatorUserRecordName: creatorUserRecordName,
            payoutPolicy: payoutPolicy,
            id: id(recordName, zoneID: zoneID)
        )
    }

    /// WHY anchor aligned: default identity matches the mock owner so owner scope resolves without override.
    @MainActor
    static func sharedHero(
        zoneID: CKRecordZone.ID,
        displayName: String = "Test Hero",
        iCloudRecordName: String = MockCloudKitService.mockUserRecordName,
        recordName: String = sharedHeroRecordName,
        familyRecordName: String = sharedFamilyRecordName,
        payoutPolicy: PayoutPolicy? = nil
    ) -> Profile {
        Profile(
            displayName: displayName,
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .hero,
            iCloudUserID: id(iCloudRecordName, zoneID: zoneID),
            family: ref(familyRecordName, zoneID: zoneID),
            payoutPolicy: payoutPolicy,
            id: id(recordName, zoneID: zoneID)
        )
    }

    /// WHY anchor aligned: default identity matches the mock owner so owner scope resolves without override.
    @MainActor
    static func sharedParent(
        zoneID: CKRecordZone.ID,
        displayName: String = "Test Parent",
        recordName: String = sharedParentRecordName,
        iCloudRecordName: String = MockCloudKitService.mockUserRecordName,
        familyRecordName: String = sharedFamilyRecordName
    ) -> Profile {
        Profile(
            displayName: displayName,
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .guildMaster,
            iCloudUserID: id(iCloudRecordName, zoneID: zoneID),
            family: ref(familyRecordName, zoneID: zoneID),
            id: id(recordName, zoneID: zoneID)
        )
    }

    /// WHY app-owned resolver persists merges against the test's cache/session.
    @MainActor
    static func appOwnedResolver(cache: CacheService, appState: AppState) -> CKSyncConflictResolver {
        CKSyncConflictResolver(cacheService: cache, appState: appState)
    }

    /// WHY app-owned handler keeps conflicts on the test's cache/session.
    @MainActor
    static func appOwnedHandler(cache: CacheService, appState: AppState) -> CKSyncEngineDelegateHandler {
        CKSyncEngineDelegateHandler(
            conflictResolver: appOwnedResolver(cache: cache, appState: appState),
            cacheService: cache,
            appState: appState
        )
    }

    static func requireCanonicalCount() {
        #expect(
            CachedRecordType.allCases.count == expectedTypeCount,
            "New CachedRecordType case requires explicit conversion coverage; add fixture and round-trip case instead of silent fallthrough."
        )
    }

    /// WHY root: the family IS the partition, so scoping it to itself is circular.
    static func verifyFamilyRoot(familyCache: FamilyCache, scopedFamilyName: String) {
        #expect(familyCache.familyRecordName.isEmpty)
        #expect(!scopedFamilyName.isEmpty)
        #expect(scopedFamilyName == familyRecordName)
    }

    static func makeFamily(zoneID: CKRecordZone.ID) -> Family {
        Family(
            name: "Guild",
            createdAt: fixedDate,
            payoutPolicy: .perQuest,
            payoutDay: .sunday,
            id: id("fam_exhaustive", zoneID: zoneID)
        )
    }

    static func makeProfile(zoneID: CKRecordZone.ID) -> Profile {
        var profile = Profile(
            displayName: "Hero",
            role: .hero,
            iCloudUserID: id("user_exhaustive", zoneID: zoneID),
            family: ref(familyRecordName, zoneID: zoneID),
            avatarEmoji: "🦊",
            splitPercentSpend: 50,
            splitPercentShort: 30,
            splitPercentLong: 20,
            interestEnabled: true,
            interestBucket: BucketKind.longTermSave.rawValue,
            interestRateBps: 250,
            interestIsCompound: true,
            matchEnabled: true,
            matchRateBps: 100,
            matchMonthlyCapPennies: 50000,
            id: id("hero_exhaustive", zoneID: zoneID)
        )
        profile.xp = 120
        profile.level = 3
        return profile
    }

    static func makeQuest(zoneID: CKRecordZone.ID) -> Quest {
        Quest(
            template: ref("tpl_exhaustive", zoneID: zoneID),
            assignee: ref("hero_exhaustive", zoneID: zoneID),
            goldReward: 500,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            weekOf: weekOf,
            createdBy: ref("creator_exhaustive", zoneID: zoneID),
            family: ref(familyRecordName, zoneID: zoneID),
            name: "Tidy Room",
            descriptionText: "Tidy up",
            id: id("quest_exhaustive", zoneID: zoneID)
        )
    }

    static func makeQuestTemplate(zoneID: CKRecordZone.ID) -> QuestTemplate {
        QuestTemplate(
            name: "Tidy Room",
            description: "Tidy up",
            defaultGold: 500,
            xpReward: 50,
            scheduleType: .specificDays,
            specificDays: ["Mon", "Wed"],
            targetCount: 2,
            isAllOrNothing: true,
            approvalMode: .parentVerify,
            createdBy: ref("creator_exhaustive", zoneID: zoneID),
            family: ref(familyRecordName, zoneID: zoneID),
            isActive: true,
            id: id("tpl_exhaustive", zoneID: zoneID)
        )
    }

    static func makeQuestCompletion(zoneID: CKRecordZone.ID) -> QuestCompletion {
        QuestCompletion(
            quest: ref("quest_exhaustive", zoneID: zoneID),
            completedBy: ref("hero_exhaustive", zoneID: zoneID),
            approvalMode: .parentVerify,
            completedDate: fixedDate,
            weekOf: weekOf,
            family: ref(familyRecordName, zoneID: zoneID),
            id: id("log_exhaustive", zoneID: zoneID)
        )
    }

    static func makeLedgerEntry(zoneID: CKRecordZone.ID) -> LedgerEntry {
        LedgerEntry(
            profile: ref("hero_exhaustive", zoneID: zoneID),
            amount: 1250,
            description: "Payout",
            location: "App",
            date: fixedDate,
            source: LedgerSource.manual.rawValue,
            bucketKind: BucketKind.longTermSave.rawValue,
            family: ref(familyRecordName, zoneID: zoneID),
            id: id("led_exhaustive", zoneID: zoneID)
        )
    }

    static func makeAllowancePeriod(zoneID: CKRecordZone.ID) -> AllowancePeriod {
        AllowancePeriod(
            weekOf: weekOf,
            profile: ref("hero_exhaustive", zoneID: zoneID),
            status: .paid,
            totalEarned: 2500,
            questsCompleted: 3,
            questsTotal: 4,
            paidDate: fixedDate,
            paidAmount: 2500,
            family: ref(familyRecordName, zoneID: zoneID),
            id: id("per_exhaustive", zoneID: zoneID)
        )
    }

    static func makeAchievement(zoneID: CKRecordZone.ID) -> Achievement {
        Achievement(
            name: "First Quest",
            description: "Complete one quest",
            iconSystemName: "star.fill",
            category: .quest,
            requirementType: .firstQuest,
            requirementValue: 1,
            family: ref(familyRecordName, zoneID: zoneID),
            id: id("ach_exhaustive", zoneID: zoneID)
        )
    }

    static func makeProfileAchievement(zoneID: CKRecordZone.ID) -> ProfileAchievement {
        ProfileAchievement(
            achievement: ref("ach_exhaustive", zoneID: zoneID),
            profile: ref("hero_exhaustive", zoneID: zoneID),
            earnedDate: fixedDate,
            family: ref(familyRecordName, zoneID: zoneID),
            id: id("pa_exhaustive", zoneID: zoneID)
        )
    }

    static func makeNotificationPreference(zoneID: CKRecordZone.ID) -> NotificationPreference {
        NotificationPreference(
            profile: ref("hero_exhaustive", zoneID: zoneID),
            eventType: .questAssigned,
            enabled: true,
            family: ref(familyRecordName, zoneID: zoneID),
            id: id("pref_exhaustive", zoneID: zoneID)
        )
    }

    static func makeGemLedger(zoneID: CKRecordZone.ID) -> GemLedger {
        GemLedger(
            profileRecordName: "hero_exhaustive",
            family: ref(familyRecordName, zoneID: zoneID),
            amount: 25,
            source: "quest",
            sourceDetail: "bonus",
            createdAt: fixedDate,
            id: id("gem_exhaustive", zoneID: zoneID)
        )
    }

    static func makeRewardEvent(zoneID: CKRecordZone.ID) -> RewardEvent {
        RewardEvent(
            profile: ref("hero_exhaustive", zoneID: zoneID),
            questCompletion: ref("log_exhaustive", zoneID: zoneID),
            xpAmount: 50,
            goldAmount: 500,
            timestamp: fixedDate,
            family: ref(familyRecordName, zoneID: zoneID),
            id: RewardEvent.recordID(completionRecordName: "log_exhaustive", zoneID: zoneID)
        )
    }

    static func makeGoal(zoneID: CKRecordZone.ID) -> Goal {
        Goal(
            profile: ref("hero_exhaustive", zoneID: zoneID),
            family: ref(familyRecordName, zoneID: zoneID),
            bucketKind: .shortTermSave,
            name: "Bike",
            category: "Ride",
            emojiIcon: "🚲",
            targetAmountPennies: 25000,
            createdAt: fixedDate,
            id: id("goal_exhaustive", zoneID: zoneID)
        )
    }

    /// WHY in-memory only: toRecord synthesizes local CKRecords, never hits the network.
    static func fixtureRecord(for type: CachedRecordType, zoneID: CKRecordZone.ID) -> CKRecord {
        switch type {
        case .family: makeFamily(zoneID: zoneID).toRecord()
        case .profile: makeProfile(zoneID: zoneID).toRecord()
        case .quest: makeQuest(zoneID: zoneID).toRecord()
        case .questTemplate: makeQuestTemplate(zoneID: zoneID).toRecord()
        case .questCompletion: makeQuestCompletion(zoneID: zoneID).toRecord()
        case .ledgerEntry: makeLedgerEntry(zoneID: zoneID).toRecord()
        case .allowancePeriod: makeAllowancePeriod(zoneID: zoneID).toRecord()
        case .achievement: makeAchievement(zoneID: zoneID).toRecord()
        case .profileAchievement: makeProfileAchievement(zoneID: zoneID).toRecord()
        case .notificationPreference: makeNotificationPreference(zoneID: zoneID).toRecord()
        case .gemLedger: makeGemLedger(zoneID: zoneID).toRecord()
        case .rewardEvent: makeRewardEvent(zoneID: zoneID).toRecord()
        case .goal: makeGoal(zoneID: zoneID).toRecord()
        }
    }

    static func verifyDirect(for type: CachedRecordType, zoneID: CKRecordZone.ID) {
        switch type {
        case .family: verifyFamily(makeFamily(zoneID: zoneID), expectedType: type, zoneID: zoneID)
        case .profile: verifyProfile(makeProfile(zoneID: zoneID), expectedType: type, zoneID: zoneID)
        case .quest: verifyQuest(makeQuest(zoneID: zoneID), expectedType: type, zoneID: zoneID)
        case .questTemplate: verifyQuestTemplate(makeQuestTemplate(zoneID: zoneID), expectedType: type, zoneID: zoneID)
        case .questCompletion: verifyQuestCompletion(makeQuestCompletion(zoneID: zoneID), expectedType: type, zoneID: zoneID)
        case .ledgerEntry: verifyLedgerEntry(makeLedgerEntry(zoneID: zoneID), expectedType: type, zoneID: zoneID)
        case .allowancePeriod: verifyAllowancePeriod(makeAllowancePeriod(zoneID: zoneID), expectedType: type, zoneID: zoneID)
        case .achievement: verifyAchievement(makeAchievement(zoneID: zoneID), expectedType: type, zoneID: zoneID)
        case .profileAchievement: verifyProfileAchievement(makeProfileAchievement(zoneID: zoneID), expectedType: type, zoneID: zoneID)
        case .notificationPreference: verifyNotificationPreference(makeNotificationPreference(zoneID: zoneID), expectedType: type, zoneID: zoneID)
        case .gemLedger: verifyGemLedger(makeGemLedger(zoneID: zoneID), expectedType: type, zoneID: zoneID)
        case .rewardEvent: verifyRewardEvent(makeRewardEvent(zoneID: zoneID), expectedType: type, zoneID: zoneID)
        case .goal: verifyGoal(makeGoal(zoneID: zoneID), expectedType: type, zoneID: zoneID)
        }
    }

    static func verifyParsed(_ parsed: ParsedRecord, expectedType: CachedRecordType, zoneID: CKRecordZone.ID) {
        switch parsed {
        case let .family(model): verifyFamily(model, expectedType: expectedType, zoneID: zoneID)
        case let .profile(model): verifyProfile(model, expectedType: expectedType, zoneID: zoneID)
        case let .quest(model): verifyQuest(model, expectedType: expectedType, zoneID: zoneID)
        case let .questTemplate(model): verifyQuestTemplate(model, expectedType: expectedType, zoneID: zoneID)
        case let .questCompletion(model): verifyQuestCompletion(model, expectedType: expectedType, zoneID: zoneID)
        case let .ledgerEntry(model): verifyLedgerEntry(model, expectedType: expectedType, zoneID: zoneID)
        case let .allowancePeriod(model): verifyAllowancePeriod(model, expectedType: expectedType, zoneID: zoneID)
        case let .achievement(model): verifyAchievement(model, expectedType: expectedType, zoneID: zoneID)
        case let .profileAchievement(model): verifyProfileAchievement(model, expectedType: expectedType, zoneID: zoneID)
        case let .notificationPreference(model): verifyNotificationPreference(model, expectedType: expectedType, zoneID: zoneID)
        case let .gemLedger(model): verifyGemLedger(model, expectedType: expectedType, zoneID: zoneID)
        case let .rewardEvent(model): verifyRewardEvent(model, expectedType: expectedType, zoneID: zoneID)
        case let .goal(model): verifyGoal(model, expectedType: expectedType, zoneID: zoneID)
        case let .ignoredSystemRecord(recordType, recordName):
            Issue.record("Unexpected ignoredSystemRecord (\(recordType)/\(recordName)) for \(expectedType).")
        case let .parseFailure(recordType, recordName):
            Issue.record("Unexpected parseFailure (\(recordType)/\(recordName)) for \(expectedType).")
        }
    }

    private static func verifyFamily(_ model: Family, expectedType: CachedRecordType, zoneID: CKRecordZone.ID) {
        var model = model
        model.changeTag = "ct-family"
        model.encodedSystemFields = Data("sys-family".utf8)
        let cache = FamilyCache(from: model)
        #expect(cache.familyRecordName.isEmpty)
        #expect(cache.recordName == model.id.recordName)
        #expect(cache.changeTag == "ct-family")
        #expect(cache.encodedSystemFields == Data("sys-family".utf8))
        let typed = cache.toFamily(zoneID: zoneID)
        let generic = cache.toDomain(zoneID: zoneID)
        #expect(typed == generic)
        #expect(typed.changeTag == "ct-family")
        #expect(typed.encodedSystemFields == Data("sys-family".utf8))
        #expect(typed.id.recordName == model.id.recordName)
        #expect(typed.name == model.name)
        #expect(expectedType == .family)
    }

    private static func verifyProfile(_ model: Profile, expectedType: CachedRecordType, zoneID: CKRecordZone.ID) {
        var model = model
        model.changeTag = "ct-profile"
        model.encodedSystemFields = Data("sys-profile".utf8)
        let cache = ProfileCache(from: model)
        #expect(cache.familyRecordName == familyRecordName)
        #expect(cache.recordName == model.id.recordName)
        #expect(cache.changeTag == "ct-profile")
        #expect(cache.encodedSystemFields == Data("sys-profile".utf8))
        let typed = cache.toProfile(zoneID: zoneID)
        let generic = cache.toDomain(zoneID: zoneID)
        #expect(typed == generic)
        #expect(typed.changeTag == "ct-profile")
        #expect(typed.encodedSystemFields == Data("sys-profile".utf8))
        #expect(typed.id.recordName == model.id.recordName)
        #expect(typed.displayName == model.displayName)
        #expect(typed.role == model.role)
        #expect(typed.iCloudUserID.recordName == model.iCloudUserID.recordName)
        #expect(expectedType == .profile)
    }

    private static func verifyQuest(_ model: Quest, expectedType: CachedRecordType, zoneID: CKRecordZone.ID) {
        var model = model
        model.changeTag = "ct-quest"
        model.encodedSystemFields = Data("sys-quest".utf8)
        let cache = QuestCache(from: model)
        #expect(cache.familyRecordName == familyRecordName)
        #expect(cache.recordName == model.id.recordName)
        #expect(cache.changeTag == "ct-quest")
        #expect(cache.encodedSystemFields == Data("sys-quest".utf8))
        let typed = cache.toQuest(zoneID: zoneID)
        let generic = cache.toDomain(zoneID: zoneID)
        #expect(typed == generic)
        #expect(typed.changeTag == "ct-quest")
        #expect(typed.encodedSystemFields == Data("sys-quest".utf8))
        #expect(typed.id.recordName == model.id.recordName)
        #expect(typed.goldReward == model.goldReward)
        #expect(typed.approvalMode == model.approvalMode)
        #expect(expectedType == .quest)
    }

    private static func verifyQuestTemplate(_ model: QuestTemplate, expectedType: CachedRecordType, zoneID: CKRecordZone.ID) {
        var model = model
        model.changeTag = "ct-questTemplate"
        model.encodedSystemFields = Data("sys-questTemplate".utf8)
        let cache = QuestTemplateCache(from: model)
        #expect(cache.familyRecordName == familyRecordName)
        #expect(cache.recordName == model.id.recordName)
        #expect(cache.changeTag == "ct-questTemplate")
        #expect(cache.encodedSystemFields == Data("sys-questTemplate".utf8))
        let typed = cache.toQuestTemplate(zoneID: zoneID)
        let generic = cache.toDomain(zoneID: zoneID)
        #expect(typed == generic)
        #expect(typed.changeTag == "ct-questTemplate")
        #expect(typed.encodedSystemFields == Data("sys-questTemplate".utf8))
        #expect(typed.id.recordName == model.id.recordName)
        #expect(typed.name == model.name)
        #expect(typed.specificDays == model.specificDays)
        #expect(expectedType == .questTemplate)
    }

    private static func verifyQuestCompletion(_ model: QuestCompletion, expectedType: CachedRecordType, zoneID: CKRecordZone.ID) {
        var model = model
        model.changeTag = "ct-questCompletion"
        model.encodedSystemFields = Data("sys-questCompletion".utf8)
        let cache = QuestCompletionCache(from: model)
        #expect(cache.familyRecordName == familyRecordName)
        #expect(cache.recordName == model.id.recordName)
        #expect(cache.changeTag == "ct-questCompletion")
        #expect(cache.encodedSystemFields == Data("sys-questCompletion".utf8))
        let typed = cache.toQuestCompletion(zoneID: zoneID)
        let generic = cache.toDomain(zoneID: zoneID)
        #expect(typed == generic)
        #expect(typed.changeTag == "ct-questCompletion")
        #expect(typed.encodedSystemFields == Data("sys-questCompletion".utf8))
        #expect(typed.id.recordName == model.id.recordName)
        #expect(typed.verificationStatus == model.verificationStatus)
        #expect(typed.quest.recordID.recordName == model.quest.recordID.recordName)
        #expect(expectedType == .questCompletion)
    }

    private static func verifyLedgerEntry(_ model: LedgerEntry, expectedType: CachedRecordType, zoneID: CKRecordZone.ID) {
        var model = model
        model.changeTag = "ct-ledgerEntry"
        model.encodedSystemFields = Data("sys-ledgerEntry".utf8)
        let cache = LedgerEntryCache(from: model)
        #expect(cache.familyRecordName == familyRecordName)
        #expect(cache.recordName == model.id.recordName)
        #expect(cache.changeTag == "ct-ledgerEntry")
        #expect(cache.encodedSystemFields == Data("sys-ledgerEntry".utf8))
        let typed = cache.toLedgerEntry(zoneID: zoneID)
        let generic = cache.toDomain(zoneID: zoneID)
        #expect(typed == generic)
        #expect(typed.changeTag == "ct-ledgerEntry")
        #expect(typed.encodedSystemFields == Data("sys-ledgerEntry".utf8))
        #expect(typed.id.recordName == model.id.recordName)
        #expect(typed.amount == model.amount)
        #expect(typed.source == model.source)
        #expect(expectedType == .ledgerEntry)
    }

    private static func verifyAllowancePeriod(_ model: AllowancePeriod, expectedType: CachedRecordType, zoneID: CKRecordZone.ID) {
        var model = model
        model.changeTag = "ct-allowancePeriod"
        model.encodedSystemFields = Data("sys-allowancePeriod".utf8)
        let cache = AllowancePeriodCache(from: model)
        #expect(cache.familyRecordName == familyRecordName)
        #expect(cache.recordName == model.id.recordName)
        #expect(cache.changeTag == "ct-allowancePeriod")
        #expect(cache.encodedSystemFields == Data("sys-allowancePeriod".utf8))
        let typed = cache.toAllowancePeriod(zoneID: zoneID)
        let generic = cache.toDomain(zoneID: zoneID)
        #expect(typed == generic)
        #expect(typed.changeTag == "ct-allowancePeriod")
        #expect(typed.encodedSystemFields == Data("sys-allowancePeriod".utf8))
        #expect(typed.id.recordName == model.id.recordName)
        #expect(typed.status == model.status)
        #expect(typed.totalEarned == model.totalEarned)
        #expect(expectedType == .allowancePeriod)
    }

    private static func verifyAchievement(_ model: Achievement, expectedType: CachedRecordType, zoneID: CKRecordZone.ID) {
        var model = model
        model.changeTag = "ct-achievement"
        model.encodedSystemFields = Data("sys-achievement".utf8)
        let cache = AchievementCache(from: model)
        #expect(cache.familyRecordName == familyRecordName)
        #expect(cache.recordName == model.id.recordName)
        #expect(cache.changeTag == "ct-achievement")
        #expect(cache.encodedSystemFields == Data("sys-achievement".utf8))
        let typed = cache.toAchievement(zoneID: zoneID)
        let generic = cache.toDomain(zoneID: zoneID)
        #expect(typed == generic)
        #expect(typed.changeTag == "ct-achievement")
        #expect(typed.encodedSystemFields == Data("sys-achievement".utf8))
        #expect(typed.id.recordName == model.id.recordName)
        #expect(typed.requirementType == model.requirementType)
        #expect(expectedType == .achievement)
    }

    private static func verifyProfileAchievement(_ model: ProfileAchievement, expectedType: CachedRecordType, zoneID: CKRecordZone.ID) {
        var model = model
        model.changeTag = "ct-profileAchievement"
        model.encodedSystemFields = Data("sys-profileAchievement".utf8)
        let cache = ProfileAchievementCache(from: model)
        #expect(cache.familyRecordName == familyRecordName)
        #expect(cache.recordName == model.id.recordName)
        #expect(cache.changeTag == "ct-profileAchievement")
        #expect(cache.encodedSystemFields == Data("sys-profileAchievement".utf8))
        let typed = cache.toProfileAchievement(zoneID: zoneID)
        let generic = cache.toDomain(zoneID: zoneID)
        #expect(typed == generic)
        #expect(typed.changeTag == "ct-profileAchievement")
        #expect(typed.encodedSystemFields == Data("sys-profileAchievement".utf8))
        #expect(typed.id.recordName == model.id.recordName)
        #expect(typed.earnedDate == model.earnedDate)
        #expect(expectedType == .profileAchievement)
    }

    private static func verifyNotificationPreference(_ model: NotificationPreference, expectedType: CachedRecordType, zoneID: CKRecordZone.ID) {
        var model = model
        model.changeTag = "ct-notificationPreference"
        model.encodedSystemFields = Data("sys-notificationPreference".utf8)
        let cache = NotificationPreferenceCache(from: model)
        #expect(cache.familyRecordName == familyRecordName)
        #expect(cache.recordName == model.id.recordName)
        #expect(cache.changeTag == "ct-notificationPreference")
        #expect(cache.encodedSystemFields == Data("sys-notificationPreference".utf8))
        let typed = cache.toNotificationPreference(zoneID: zoneID)
        let generic = cache.toDomain(zoneID: zoneID)
        #expect(typed == generic)
        #expect(typed.changeTag == "ct-notificationPreference")
        #expect(typed.encodedSystemFields == Data("sys-notificationPreference".utf8))
        #expect(typed.id.recordName == model.id.recordName)
        #expect(typed.eventType == model.eventType)
        #expect(typed.enabled == model.enabled)
        #expect(expectedType == .notificationPreference)
    }

    private static func verifyGemLedger(_ model: GemLedger, expectedType: CachedRecordType, zoneID: CKRecordZone.ID) {
        var model = model
        model.changeTag = "ct-gemLedger"
        model.encodedSystemFields = Data("sys-gemLedger".utf8)
        let cache = GemLedgerCache(from: model)
        #expect(cache.familyRecordName == familyRecordName)
        #expect(cache.recordName == model.id.recordName)
        #expect(cache.changeTag == "ct-gemLedger")
        #expect(cache.encodedSystemFields == Data("sys-gemLedger".utf8))
        let typed = cache.toGemLedger(zoneID: zoneID)
        let generic = cache.toDomain(zoneID: zoneID)
        #expect(typed == generic)
        #expect(typed.changeTag == "ct-gemLedger")
        #expect(typed.encodedSystemFields == Data("sys-gemLedger".utf8))
        #expect(typed.id.recordName == model.id.recordName)
        #expect(typed.amount == model.amount)
        #expect(typed.profileRecordName == model.profileRecordName)
        #expect(expectedType == .gemLedger)
    }

    private static func verifyRewardEvent(_ model: RewardEvent, expectedType: CachedRecordType, zoneID: CKRecordZone.ID) {
        var model = model
        model.changeTag = "ct-rewardEvent"
        model.encodedSystemFields = Data("sys-rewardEvent".utf8)
        let cache = RewardEventCache(from: model)
        #expect(cache.familyRecordName == familyRecordName)
        #expect(cache.recordName == model.id.recordName)
        #expect(cache.changeTag == "ct-rewardEvent")
        #expect(cache.encodedSystemFields == Data("sys-rewardEvent".utf8))
        let typed = cache.toRewardEvent(zoneID: zoneID)
        let generic = cache.toDomain(zoneID: zoneID)
        #expect(typed == generic)
        #expect(typed.changeTag == "ct-rewardEvent")
        #expect(typed.encodedSystemFields == Data("sys-rewardEvent".utf8))
        #expect(typed.id.recordName == model.id.recordName)
        #expect(typed.xpAmount == model.xpAmount)
        #expect(typed.goldAmount == model.goldAmount)
        #expect(expectedType == .rewardEvent)
    }

    private static func verifyGoal(_ model: Goal, expectedType: CachedRecordType, zoneID: CKRecordZone.ID) {
        var model = model
        model.changeTag = "ct-goal"
        model.encodedSystemFields = Data("sys-goal".utf8)
        let cache = GoalCache(from: model)
        #expect(cache.familyRecordName == familyRecordName)
        #expect(cache.recordName == model.id.recordName)
        #expect(cache.changeTag == "ct-goal")
        #expect(cache.encodedSystemFields == Data("sys-goal".utf8))
        let typed = cache.toGoal(zoneID: zoneID)
        let generic = cache.toDomain(zoneID: zoneID)
        #expect(typed == generic)
        #expect(typed.changeTag == "ct-goal")
        #expect(typed.encodedSystemFields == Data("sys-goal".utf8))
        #expect(typed.id.recordName == model.id.recordName)
        #expect(typed.name == model.name)
        #expect(typed.targetAmountPennies == model.targetAmountPennies)
        #expect(expectedType == .goal)
    }
}
