//
//  GoalEnhancementTests.swift
//  LootListTests
//
//  Created by Ben Mackin on 8/29/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

struct GoalEnhancementTests {
    @Test
    func `goal serialization and deserialization with new fields`() throws {
        let zoneID = CKRecordZone.ID(zoneName: "family-zone", ownerName: "owner")
        let goalID = CKRecord.ID(recordName: "test-goal-1", zoneID: zoneID)
        let profileRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "hero-1", zoneID: zoneID), action: .none)
        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam-1", zoneID: zoneID), action: .none)

        let targetDate = Date().addingTimeInterval(86400 * 45)
        let linkURL = "https://www.amazon.com/dp/B08N5WRWNW"
        let imageURL = "https://images.example.com/item.png"

        let goal = Goal(
            profile: profileRef,
            family: familyRef,
            bucketKind: .shortTermSave,
            name: "Lego Castle",
            category: "Toys",
            emojiIcon: "🏰",
            targetAmountPennies: 9999,
            createdAt: Date(),
            targetDate: targetDate,
            linkURL: linkURL,
            imageURL: imageURL,
            id: goalID
        )

        let record = goal.toRecord()
        let decoded = try Goal(record: record)

        #expect(decoded.name == "Lego Castle")
        #expect(decoded.category == "Toys")
        #expect(decoded.emojiIcon == "🏰")
        #expect(decoded.targetAmountPennies == 9999)
        #expect(decoded.targetDate != nil)
        #expect(decoded.linkURL == linkURL)
        #expect(decoded.imageURL == imageURL)
    }

    @Test
    func `goal cache bridge round trip`() {
        let zoneID = CKRecordZone.ID(zoneName: "family-zone", ownerName: "owner")
        let goalID = CKRecord.ID(recordName: "test-goal-2", zoneID: zoneID)
        let profileRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "hero-1", zoneID: zoneID), action: .none)
        let familyRef = CKRecord.Reference(recordID: CKRecord.ID(recordName: "fam-1", zoneID: zoneID), action: .none)

        let targetDate = Date().addingTimeInterval(86400 * 60)
        let linkURL = "https://target.com/p/item"

        let goal = Goal(
            profile: profileRef,
            family: familyRef,
            bucketKind: .longTermSave,
            name: "Nintendo Switch",
            category: "Electronics",
            emojiIcon: "🎮",
            targetAmountPennies: 29999,
            createdAt: Date(),
            targetDate: targetDate,
            linkURL: linkURL,
            imageURL: nil,
            id: goalID
        )

        let cache = GoalCache(from: goal)
        #expect(cache.name == "Nintendo Switch")
        #expect(cache.targetDate == targetDate)
        #expect(cache.linkURL == linkURL)

        let bridgedGoal = cache.toGoal(zoneID: zoneID)
        #expect(bridgedGoal.name == goal.name)
        #expect(bridgedGoal.targetDate == goal.targetDate)
        #expect(bridgedGoal.linkURL == goal.linkURL)
    }

    @Test
    func `link metadata URL normalization`() {
        #expect(LinkMetadataService.normalizeURL(from: "   https://amazon.com/item   ")?.host == "amazon.com")
        #expect(LinkMetadataService.normalizeURL(from: "target.com/p/123")?.host == "target.com")
        #expect(LinkMetadataService.normalizeURL(from: "   ") == nil)
        #expect(LinkMetadataService.normalizeURL(from: "invalid-url-with-no-domain") == nil)
    }
}
