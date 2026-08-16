//
//  CacheConversionsTests.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
@testable import LootList
import SwiftData
import Testing

struct CacheConversionsTests {
    // MARK: - Helpers

    private let zoneID = CKRecordZone.ID(
        zoneName: "TestZone",
        ownerName: "_a1b2c3d4"
    )

    private func ref(_ name: String) -> CKRecord.Reference {
        CKRecord.Reference(
            recordID: CKRecord.ID(recordName: name, zoneID: zoneID),
            action: .none
        )
    }

    private func id(_ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    @Test
    func `questCompletion round-trip preserves parentVerify approvalMode`() {
        let completedDate = Date(timeIntervalSince1970: 1_750_000_000)
        let weekOf = Date(timeIntervalSince1970: 1_749_950_000)

        let completion = QuestCompletion(
            quest: ref("quest_1"),
            completedBy: ref("hero_1"),
            approvalMode: .parentVerify,
            completedDate: completedDate,
            weekOf: weekOf,
            family: ref("fam_1"),
            id: id("log_1")
        )
        // cache derivation reverses).
        #expect(completion.verificationStatus == .pending)

        let cache = QuestCompletionCache(from: completion)

        // The cache must NOT hardcode `.autoApprove` — it must store the
        // approval mode derived from the completion's verification status.
        #expect(cache.approvalMode == ApprovalMode.parentVerify.rawValue)
        #expect(cache.verificationStatus == VerificationStatus.pending.rawValue)
        #expect(cache.recordName == "log_1")
        #expect(cache.questRecordName == "quest_1")
        #expect(cache.completerRecordName == "hero_1")
        #expect(cache.familyRecordName == "fam_1")
        #expect(cache.weekOf == weekOf)
        #expect(cache.completedDate == completedDate)

        let roundtripped = cache.toQuestCompletion(zoneID: zoneID)

        // approvalMode is reconstructed from the cached string, not hardcoded.
        #expect(roundtripped.verificationStatus == .pending)
        #expect(roundtripped.id == id("log_1"))
        #expect(roundtripped.quest == ref("quest_1"))
        #expect(roundtripped.completedBy == ref("hero_1"))
        #expect(roundtripped.family == ref("fam_1"))
        #expect(roundtripped.weekOf == weekOf)
        #expect(roundtripped.completedDate == completedDate)
    }

    @Test
    func `questCompletion round-trip preserves autoApprove approvalMode`() {
        let weekOf = Date(timeIntervalSince1970: 1_749_950_000)

        let completion = QuestCompletion(
            quest: ref("quest_2"),
            completedBy: ref("hero_2"),
            approvalMode: .autoApprove,
            weekOf: weekOf,
            family: ref("fam_2"),
            id: id("log_2")
        )
        #expect(completion.verificationStatus == .autoApproved)

        let cache = QuestCompletionCache(from: completion)
        #expect(cache.approvalMode == ApprovalMode.autoApprove.rawValue)
        #expect(cache.verificationStatus == VerificationStatus.autoApproved.rawValue)

        let roundtripped = cache.toQuestCompletion(zoneID: zoneID)
        #expect(roundtripped.verificationStatus == .autoApproved)
        #expect(roundtripped.id == id("log_2"))
    }

    @Test
    func `questCompletion round-trip preserves verified status and verifier`() {
        let verifiedDate = Date(timeIntervalSince1970: 1_750_050_000)
        let weekOf = Date(timeIntervalSince1970: 1_749_950_000)

        // pass through `.verified`).
        var completion = QuestCompletion(
            quest: ref("quest_3"),
            completedBy: ref("hero_3"),
            approvalMode: .parentVerify,
            weekOf: weekOf,
            family: ref("fam_3"),
            id: id("log_3")
        )
        completion.verificationStatus = .verified
        completion.verifiedBy = ref("parent_3")
        completion.verifiedDate = verifiedDate

        let cache = QuestCompletionCache(from: completion)
        #expect(cache.approvalMode == ApprovalMode.parentVerify.rawValue)
        #expect(cache.verificationStatus == VerificationStatus.verified.rawValue)
        #expect(cache.verifiedByRecordName == "parent_3")
        #expect(cache.verifiedDate == verifiedDate)

        let roundtripped = cache.toQuestCompletion(zoneID: zoneID)
        #expect(roundtripped.verificationStatus == .verified)
        #expect(roundtripped.verifiedBy == ref("parent_3"))
        #expect(roundtripped.verifiedDate == verifiedDate)
    }

    @Test
    func `questCompletionCache approvalModeEnum falls back to autoApprove on garbage`() {
        // Unknown raw value must fall back gracefully (mirrors QuestCache /
        // QuestTemplateCache `approvalModeEnum` fallback behavior).
        let weekOf = Date(timeIntervalSince1970: 1_749_950_000)
        let cache = QuestCompletionCache(
            recordName: "log_x", questRecordName: "q", familyRecordName: "f",
            completerRecordName: "h", completedDate: weekOf, weekOf: weekOf,
            verificationStatus: "pending", approvalMode: "nonsense",
            verifiedByRecordName: nil, verifiedDate: nil
        )
        #expect(cache.approvalModeEnum == nil)
        #expect((cache.approvalModeEnum ?? .autoApprove) == .autoApprove)
    }

    // MARK: - Dedup identity

    @Test
    func `questCache toQuest produces expected domain fields`() {
        let weekOf = Date(timeIntervalSince1970: 1_749_950_000)
        let cache = questCacheFixture(
            recordName: "quest_1",
            familyRecordName: "fam_1",
            assigneeRecordName: "hero_1",
            templateRecordName: "tpl_1",
            weekOf: weekOf,
            questName: "Tidy Room",
            approvalMode: ApprovalMode.parentVerify.rawValue
        )

        let quest = cache.toQuest(zoneID: zoneID)

        #expect(quest.id == id("quest_1"))
        #expect(quest.template == ref("tpl_1"))
        #expect(quest.assignee == ref("hero_1"))
        #expect(quest.family == ref("fam_1"))
        #expect(quest.createdBy == ref("creator_1"))
        #expect(quest.goldReward == 5.0)
        #expect(quest.xpReward == 50)
        #expect(quest.approvalMode == .parentVerify)
        #expect(quest.scheduleType == .weeklyFlexible)
        #expect(quest.isAllOrNothing == false)
        #expect(quest.active == true)
        #expect(quest.weekOf == weekOf)
        #expect(quest.displayName == "Tidy Room")
        #expect(quest.descriptionText == "Tidy up")
    }

    @Test
    func `questCache rarityEnum derives from xpReward when stored rarity is stale`() {
        // A row whose stored rarity string predates an XP↔rarity constants change
        // must still report the rarity derived from its current xpReward.
        let weekOf = Date(timeIntervalSince1970: 1_749_950_000)
        let cache = QuestCache(
            recordName: "quest_stale_rarity",
            familyRecordName: "fam_1",
            assigneeRecordName: "hero_1",
            templateRecordName: "tpl_1",
            weekOf: weekOf,
            questName: "Tidy Room",
            isActive: true,
            goldReward: 5.0,
            xpReward: 100,
            rarity: QuestRarity.common.rawValue, // stale: 100 XP maps to Rare today
            scheduleType: QuestSchedule.weeklyFlexible.rawValue,
            isAllOrNothing: false,
            approvalMode: ApprovalMode.parentVerify.rawValue,
            descriptionText: "Tidy up",
            createdByRecordName: "creator_1"
        )

        #expect(cache.rarity == QuestRarity.common.rawValue)
        #expect(cache.rarityEnum == .rare)
    }

    @Test
    func `questCache rarityEnum falls back to stored string for legacy rows`() {
        // Legacy rows that predate a meaningful xpReward (0) fall back to the
        // stored raw string instead of degrading to the zero-XP derivation.
        let weekOf = Date(timeIntervalSince1970: 1_749_950_000)
        let cache = QuestCache(
            recordName: "quest_legacy_rarity",
            familyRecordName: "fam_1",
            assigneeRecordName: "hero_1",
            templateRecordName: "tpl_1",
            weekOf: weekOf,
            questName: "Legacy Quest",
            isActive: true,
            goldReward: 5.0,
            xpReward: 0,
            rarity: QuestRarity.legendary.rawValue,
            scheduleType: QuestSchedule.weeklyFlexible.rawValue,
            isAllOrNothing: false,
            approvalMode: ApprovalMode.autoApprove.rawValue,
            descriptionText: nil,
            createdByRecordName: "creator_1"
        )

        #expect(cache.rarityEnum == .legendary)
    }

    @Test
    func `questCache update preserves stored rarity string as legacy fallback`() {
        // The write path no longer re-stamps the derived rarity into the stored
        // string; rarityEnum keeps deriving from xpReward at read time.
        let weekOf = Date(timeIntervalSince1970: 1_749_950_000)
        let cache = questCacheFixture(
            recordName: "quest_1",
            familyRecordName: "fam_1",
            assigneeRecordName: "hero_1",
            templateRecordName: "tpl_1",
            weekOf: weekOf,
            questName: "Tidy Room",
            approvalMode: ApprovalMode.parentVerify.rawValue
        )
        // fixture: xpReward 50, stored rarity "common"

        let epicQuest = Quest(
            template: ref("tpl_1"),
            assignee: ref("hero_1"),
            goldReward: 5.0,
            xpReward: 250,
            scheduleType: .weeklyFlexible,
            weekOf: weekOf,
            createdBy: ref("creator_1"),
            family: ref("fam_1"),
            name: "Tidy Room",
            descriptionText: "Tidy up",
            id: id("quest_1")
        )
        cache.update(from: epicQuest)

        #expect(cache.xpReward == 250)
        #expect(cache.rarity == QuestRarity.common.rawValue) // unchanged legacy fallback
        #expect(cache.rarityEnum == .epic)
    }

    @Test
    func `questTemplateCache toQuestTemplate produces expected domain fields`() {
        let cache = QuestTemplateCache(
            recordName: "tpl_1",
            familyRecordName: "fam_1",
            name: "Tidy Room",
            isActive: true,
            goldReward: 5.0,
            xpReward: 50,
            rarity: "common",
            specificDays: ["Mon", "Wed"],
            templateDescription: "Tidy up",
            scheduleType: "specificDays",
            isAllOrNothing: true,
            approvalMode: ApprovalMode.parentVerify.rawValue,
            createdByRecordName: "creator_1"
        )

        let template = cache.toQuestTemplate(zoneID: zoneID)

        #expect(template.id == id("tpl_1"))
        #expect(template.name == "Tidy Room")
        #expect(template.description == "Tidy up")
        #expect(template.defaultGold == 5.0)
        #expect(template.xpReward == 50)
        #expect(template.scheduleType == .specificDays)
        #expect(template.specificDays == ["Mon", "Wed"])
        #expect(template.isAllOrNothing == true)
        #expect(template.approvalMode == .parentVerify)
        #expect(template.isActive == true)
        #expect(template.createdBy == ref("creator_1"))
        #expect(template.family == ref("fam_1"))
    }

    @Test
    func `ledgerEntryCache toLedgerEntry produces expected domain fields`() {
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let cache = LedgerEntryCache(
            recordName: "led_1",
            profileRecordName: "hero_1",
            familyRecordName: "fam_1",
            amount: 12.5,
            entryDescription: "Bonus payout",
            date: date,
            source: "manual"
        )

        let entry = cache.toLedgerEntry(zoneID: zoneID)

        #expect(entry.id == id("led_1"))
        #expect(entry.profile == ref("hero_1"))
        #expect(entry.family == ref("fam_1"))
        #expect(entry.amount == 12.5)
        #expect(entry.description == "Bonus payout")
        #expect(entry.date == date)
        #expect(entry.source == "manual")
    }

    @Test
    func `allowancePeriodCache toAllowancePeriod produces expected domain fields`() {
        let weekOf = Date(timeIntervalSince1970: 1_749_950_000)
        let paidDate = Date(timeIntervalSince1970: 1_750_100_000)
        let cache = AllowancePeriodCache(
            recordName: "per_1",
            profileRecordName: "hero_1",
            familyRecordName: "fam_1",
            weekOf: weekOf,
            status: PayoutStatus.paid.rawValue,
            totalEarned: 25.0,
            questsCompleted: 3,
            questsTotal: 4,
            paidDate: paidDate,
            paidAmount: 25.0
        )

        let period = cache.toAllowancePeriod(zoneID: zoneID)

        #expect(period.id == id("per_1"))
        #expect(period.profile == ref("hero_1"))
        #expect(period.family == ref("fam_1"))
        #expect(period.weekOf == weekOf)
        #expect(period.status == .paid)
        #expect(period.totalEarned == 25.0)
        #expect(period.questsCompleted == 3)
        #expect(period.questsTotal == 4)
        #expect(period.paidDate == paidDate)
        #expect(period.paidAmount == 25.0)
    }

    // MARK: - Fixture helpers

    @Test
    func `persistedDatabaseScope parses valid database scopes and handles nil or unknown gracefully`() {
        let questPrivate = questCacheFixture(
            recordName: "q_pvt",
            familyRecordName: "fam_1",
            assigneeRecordName: "hero_1",
            templateRecordName: "tpl_1",
            weekOf: Date(),
            questName: "Quest Pvt",
            approvalMode: ApprovalMode.autoApprove.rawValue,
            sourceZoneName: "CustomZone",
            sourceZoneOwnerName: "_user1",
            sourceDatabaseScope: "private"
        )
        #expect(questPrivate.persistedDatabaseScope == CKDatabase.Scope.private)
        #expect(questPrivate.validatedDatabaseScope(expectedScope: .private) == CKDatabase.Scope.private)
        #expect(questPrivate.validatedDatabaseScope(expectedScope: .shared) == nil)

        let questShared = questCacheFixture(
            recordName: "q_shd",
            familyRecordName: "fam_1",
            assigneeRecordName: "hero_1",
            templateRecordName: "tpl_1",
            weekOf: Date(),
            questName: "Quest Shd",
            approvalMode: ApprovalMode.autoApprove.rawValue,
            sourceZoneName: "CustomZone",
            sourceZoneOwnerName: "_user2",
            sourceDatabaseScope: "shared"
        )
        #expect(questShared.persistedDatabaseScope == CKDatabase.Scope.shared)
        #expect(questShared.validatedDatabaseScope(expectedScope: .shared) == CKDatabase.Scope.shared)
        #expect(questShared.validatedDatabaseScope(expectedScope: .private) == nil)

        let familyRow = FamilyCache(
            recordName: "fam_1",
            name: "Guild",
            createdByRecordName: "creator_1",
            createdAt: Date(),
            payoutPolicy: PayoutPolicy.perQuest.rawValue,
            sourceZoneName: "FamilyZone",
            sourceZoneOwnerName: "_owner",
            sourceDatabaseScope: "private"
        )
        #expect(familyRow.persistedDatabaseScope == CKDatabase.Scope.private)
        #expect(familyRow.validatedDatabaseScope(expectedScope: .private) == CKDatabase.Scope.private)
        #expect(familyRow.validatedDatabaseScope(expectedScope: .shared) == nil)

        let unpersistedScope = questCacheFixture(
            recordName: "q_none",
            familyRecordName: "fam_1",
            assigneeRecordName: "hero_1",
            templateRecordName: "tpl_1",
            weekOf: Date(),
            questName: "Quest None",
            approvalMode: ApprovalMode.autoApprove.rawValue,
            sourceDatabaseScope: nil
        )
        #expect(unpersistedScope.persistedDatabaseScope == nil)
        #expect(unpersistedScope.validatedDatabaseScope(expectedScope: .shared) == CKDatabase.Scope.shared)
        #expect(inferDatabaseScope(from: CKRecordZone.ID(zoneName: "Zone", ownerName: CKCurrentUserDefaultName)) == "private")
        #expect(inferDatabaseScope(from: CKRecordZone.ID(zoneName: "Zone", ownerName: "TestOwner")) == "private")
        #expect(inferDatabaseScope(from: CKRecordZone.ID(zoneName: "Zone", ownerName: "_sharedUser123")) == "shared")
    }

    private func questCacheFixture(
        recordName: String,
        familyRecordName: String,
        assigneeRecordName: String,
        templateRecordName: String,
        weekOf: Date,
        questName: String,
        approvalMode: String,
        sourceZoneName: String? = nil,
        sourceZoneOwnerName: String? = nil,
        sourceDatabaseScope: String? = nil
    ) -> QuestCache {
        QuestCache(
            recordName: recordName,
            familyRecordName: familyRecordName,
            assigneeRecordName: assigneeRecordName,
            templateRecordName: templateRecordName,
            weekOf: weekOf,
            questName: questName,
            isActive: true,
            goldReward: 5.0,
            xpReward: 50,
            rarity: QuestRarity.common.rawValue,
            scheduleType: QuestSchedule.weeklyFlexible.rawValue,
            isAllOrNothing: false,
            approvalMode: approvalMode,
            descriptionText: "Tidy up",
            createdByRecordName: "creator_1",
            sourceZoneName: sourceZoneName,
            sourceZoneOwnerName: sourceZoneOwnerName,
            sourceDatabaseScope: sourceDatabaseScope
        )
    }
}
