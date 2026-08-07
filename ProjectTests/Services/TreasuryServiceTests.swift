//
//  TreasuryServiceTests.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

@MainActor
struct TreasuryServiceTests {
    private func makeTestData() -> (TreasuryService, CloudKitService) {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = CloudKitService(zoneID: zoneID)
        let treasury = TreasuryService(cloudKit: cloudKit)
        return (treasury, cloudKit)
    }

    @Test
    func `monday of week calculation`() {
        let now = Date()
        let monday = TreasuryService.mondayOfWeek(for: now)
        let cal = Calendar.iso8601UTC

        // Monday start of day check
        let weekday = cal.component(.weekday, from: monday)
        #expect(weekday == 2) // 2 represents Monday in ISO8601 calendar
    }

    @Test
    func `week range interval calculation`() {
        let monday = TreasuryService.mondayOfWeek(for: Date())
        let range = TreasuryService.weekRange(starting: monday)

        let durationSeconds = range.upperBound.timeIntervalSince(range.lowerBound)
        #expect(durationSeconds == Double(AppConstants.Time.secondsInWeek))
    }

    @Test
    func `weekRange is half-open and agrees with WeekMath`() {
        let monday = WeekMath.mondayOfWeek(for: Date())
        let treasuryRange = TreasuryService.weekRange(starting: monday)
        let weekMathRange = WeekMath.weekRange(starting: monday)

        #expect(treasuryRange.lowerBound == weekMathRange.lowerBound)
        #expect(treasuryRange.upperBound == weekMathRange.upperBound)
        #expect(treasuryRange == weekMathRange)
    }

    @Test
    func `completion at last second of week is included by both services`() {
        let monday = WeekMath.mondayOfWeek(for: Date())
        let secondsInWeek = TimeInterval(AppConstants.Time.secondsInWeek)
        // start + secondsInWeek - epsilon (1 second before the next Monday)
        let lastSecond = monday.addingTimeInterval(secondsInWeek - 1)

        let treasuryRange = TreasuryService.weekRange(starting: monday)
        let questRange = QuestService.weekRange(for: monday)

        // Half-open [start, end): last second (end - 1s) is contained.
        #expect(treasuryRange.contains(lastSecond))
        #expect(questRange.contains(lastSecond))
    }

    @Test
    func `completion at exactly start + secondsInWeek is excluded by both services`() {
        let monday = WeekMath.mondayOfWeek(for: Date())
        let secondsInWeek = TimeInterval(AppConstants.Time.secondsInWeek)
        // Exactly the next Monday 00:00:00 — belongs to the FOLLOWING week.
        let nextWeekStart = monday.addingTimeInterval(secondsInWeek)

        let treasuryRange = TreasuryService.weekRange(starting: monday)
        let questRange = QuestService.weekRange(for: monday)
        let nextTreasuryRange = TreasuryService.weekRange(starting: nextWeekStart)
        let nextQuestRange = QuestService.weekRange(for: nextWeekStart)

        // Excluded from THIS week...
        #expect(!treasuryRange.contains(nextWeekStart))
        #expect(!questRange.contains(nextWeekStart))
        // ...and included by the NEXT week's range.
        #expect(nextTreasuryRange.contains(nextWeekStart))
        #expect(nextQuestRange.contains(nextWeekStart))
    }

    @Test
    func `mondayOfWeek is consistent across all callers`() {
        let now = Date()

        let weekMath = WeekMath.mondayOfWeek(for: now)
        let weekMathAlias = WeekMath.weekOf(date: now)
        let treasury = TreasuryService.mondayOfWeek(for: now)
        let quest = QuestService.mondayOfWeek(for: now)

        #expect(weekMath == weekMathAlias)
        #expect(weekMath == treasury)
        #expect(weekMath == quest)
    }

    @Test
    func `weekly breakdown default initialization`() {
        let breakdown = TreasuryService.WeeklyBreakdown()
        #expect(breakdown.questsCount == 0)
        #expect(breakdown.goldFromQuests == 0)
        #expect(breakdown.bonusGold == 0)
        #expect(breakdown.totalEarned == 0)
        #expect(breakdown.spent == 0)
        #expect(breakdown.net == 0)
    }

    @Test
    func `sumGold reads gold from cache with zero CloudKit fetches`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = CloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let treasury = TreasuryService(cloudKit: cloudKit, cacheService: cache)

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
            completedBy: CKRecord.Reference(recordID: profileID, action: .none),
            approvalMode: .autoApprove,
            weekOf: monday,
            family: familyRef
        )

        let family = Family(
            name: "Test Guild",
            createdBy: CKRecord.ID(recordName: "parent1", zoneID: zoneID),
            payoutDay: .sunday,
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )

        cache.upsertQuest(quest)
        cache.upsertQuestCompletions([completion])
        // A completed sync pass stamped this family's completion cache fresh,
        // so weeklyBreakdown's cache-first gates trust the partial cache.
        cache.markCacheFresh(familyRecordName: "fam1", type: .questCompletion)

        let breakdown = try await treasury.weeklyBreakdown(profile: profile, family: family, weekOf: monday)

        // Gold must come from cache (25.0).  If code hit CK instead,
        // goldFromQuests would be 0 (empty mockRecords → fetch throws → try? swallows).
        #expect(breakdown.goldFromQuests == 25.0)
        #expect(breakdown.questsCount == 1)
    }

    @Test
    func `sumGold falls back to CloudKit on cache miss`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = CloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let treasury = TreasuryService(cloudKit: cloudKit, cacheService: cache)

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
            goldReward: 30.0,
            xpReward: 60,
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

        let family = Family(
            name: "Test Guild",
            createdBy: CKRecord.ID(recordName: "parent1", zoneID: zoneID),
            payoutDay: .sunday,
            id: CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        )

        // Seed CloudKit only — cache is empty (cache-miss scenario).
        cloudKit.seedMockRecords([quest, completion])

        let breakdown = try await treasury.weeklyBreakdown(profile: profile, family: family, weekOf: monday)

        // Gold must come from CloudKit fallback (30.0).
        #expect(breakdown.goldFromQuests == 30.0)
        #expect(breakdown.questsCount == 1)
    }

    @Test
    func `weeklyBreakdown honors family payoutDay fallback when profile has none`() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "TestZone", ownerName: "TestOwner")
        let cloudKit = CloudKitService(zoneID: zoneID)
        let cache = try CacheService(inMemory: true)
        let treasury = TreasuryService(cloudKit: cloudKit, cacheService: cache)

        let familyID = CKRecord.ID(recordName: "fam1", zoneID: zoneID)
        let familyRef = CKRecord.Reference(recordID: familyID, action: .none)
        let profileID = CKRecord.ID(recordName: "hero1", zoneID: zoneID)
        // Custom family payout day (.friday); the hero carries no per-profile override.
        let family = Family(
            name: "Friday Guild",
            createdBy: CKRecord.ID(recordName: "parent1", zoneID: zoneID),
            payoutDay: .friday,
            id: familyID
        )
        let profile = Profile(
            displayName: "Hero",
            avatarClass: .knight,
            avatarPresetID: "knight_01",
            role: .hero,
            iCloudUserID: profileID,
            family: familyRef,
            id: profileID
        )

        let cal = Calendar.iso8601UTC
        // Monday 2026-08-03 — the reference weekOf.
        let monday = try #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 3)))
        // Saturday 2026-08-01 — the .friday cycle start. This completion falls in
        // the .sunday-aligned PRIOR week but the .friday-aligned CURRENT week
        // ([2026-08-01, 2026-08-08)), so it discriminates the two boundaries.
        let boundarySaturday = try #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 1)))
        // Tuesday 2026-08-04 — inside both the .sunday and .friday current weeks (control).
        let midWeekTuesday = try #require(cal.date(from: DateComponents(year: 2026, month: 8, day: 4)))

        let templateRef = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "tmpl1", zoneID: zoneID), action: .none
        )
        let controlQuestID = CKRecord.ID(recordName: "quest1", zoneID: zoneID)
        let boundaryQuestID = CKRecord.ID(recordName: "quest2", zoneID: zoneID)
        let controlQuest = Quest(
            template: templateRef,
            assignee: CKRecord.Reference(recordID: profileID, action: .none),
            goldReward: 25.0,
            xpReward: 50,
            scheduleType: .weeklyFlexible,
            isAllOrNothing: false,
            approvalMode: .autoApprove,
            weekOf: monday,
            createdBy: familyRef,
            family: familyRef,
            name: "Control Quest",
            id: controlQuestID
        )
        let boundaryQuest = Quest(
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
            name: "Boundary Quest",
            id: boundaryQuestID
        )
        let controlCompletion = QuestCompletion(
            quest: CKRecord.Reference(recordID: controlQuestID, action: .none),
            completedBy: CKRecord.Reference(recordID: profileID, action: .none),
            approvalMode: .autoApprove,
            weekOf: midWeekTuesday,
            family: familyRef
        )
        let boundaryCompletion = QuestCompletion(
            quest: CKRecord.Reference(recordID: boundaryQuestID, action: .none),
            completedBy: CKRecord.Reference(recordID: profileID, action: .none),
            approvalMode: .autoApprove,
            weekOf: boundarySaturday,
            family: familyRef
        )

        cache.upsertQuest(controlQuest)
        cache.upsertQuest(boundaryQuest)
        cache.upsertQuestCompletions([controlCompletion, boundaryCompletion])
        cache.markCacheFresh(familyRecordName: "fam1", type: .questCompletion)

        let breakdown = try await treasury.weeklyBreakdown(profile: profile, family: family, weekOf: monday)

        // Both completions must land in the .friday-anchored current week:
        // 25.0 (control) + 40.0 (boundary). With the old .sunday fallback the
        // Saturday completion bucketed into the prior week, yielding 25.0/1.
        #expect(breakdown.goldFromQuests == 65.0)
        #expect(breakdown.questsCount == 2)
    }
}
