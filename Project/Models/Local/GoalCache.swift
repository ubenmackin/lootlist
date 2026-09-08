//
//  GoalCache.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import CloudKit
import Foundation
import SwiftData

@Model
final class GoalCache: FamilyScopedCache, CacheMergeable {
    typealias DomainModel = Goal

    #Index<GoalCache>([\.familyRecordName, \.recordName], [\.familyRecordName, \.profileRecordName, \.bucketKind, \.createdAt])

    var recordName: String
    var profileRecordName: String
    var familyRecordName: String
    var bucketKind: String
    var name: String
    var category: String?
    var emojiIcon: String?
    var targetAmountPennies: Int64
    var createdAt: Date
    var completedAt: Date?
    var isArchived: Bool
    var targetDate: Date?
    var linkURL: String?
    var imageURL: String?
    var changeTag: String?
    var encodedSystemFields: Data?
    var sourceZoneName: String?
    var sourceZoneOwnerName: String?
    var sourceDatabaseScope: String?

    var bucketKindEnum: BucketKind? {
        BucketKind(rawValue: bucketKind)
    }

    /// Shared funding-eligibility predicate: open rows that still accept funds in FIFO fills.
    /// WHY shared: funding flows must agree on what counts as fundable; listed rows below include completed.
    var isActiveGoal: Bool {
        !isArchived && completedAt == nil
    }

    /// Shared listed predicate: every non-archived row the wishlist and hero checklist count.
    /// WHY shared: completed rows stay visible with a badge, so listing must not reuse funding eligibility.
    var isListedGoal: Bool {
        !isArchived
    }

    init(recordName: String,
         profileRecordName: String,
         familyRecordName: String,
         bucketKind: String,
         name: String,
         category: String? = nil,
         emojiIcon: String? = nil,
         targetAmountPennies: Int64,
         createdAt: Date,
         completedAt: Date? = nil,
         isArchived: Bool = false,
         targetDate: Date? = nil,
         linkURL: String? = nil,
         imageURL: String? = nil,
         changeTag: String? = nil,
         encodedSystemFields: Data? = nil,
         sourceZoneName: String? = nil,
         sourceZoneOwnerName: String? = nil,
         sourceDatabaseScope: String? = nil)
    {
        self.recordName = recordName
        self.profileRecordName = profileRecordName
        self.familyRecordName = familyRecordName
        self.bucketKind = bucketKind
        self.name = name
        self.category = category
        self.emojiIcon = emojiIcon
        self.targetAmountPennies = targetAmountPennies
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.isArchived = isArchived
        self.targetDate = targetDate
        self.linkURL = linkURL
        self.imageURL = imageURL
        self.changeTag = changeTag
        self.encodedSystemFields = encodedSystemFields
        self.sourceZoneName = sourceZoneName
        self.sourceZoneOwnerName = sourceZoneOwnerName
        self.sourceDatabaseScope = sourceDatabaseScope
    }

    convenience init(from goal: Goal) {
        self.init(
            recordName: goal.id.recordName,
            profileRecordName: goal.profile.recordID.recordName,
            familyRecordName: goal.family.recordID.recordName,
            bucketKind: goal.bucketKind,
            name: goal.name,
            category: goal.category,
            emojiIcon: goal.emojiIcon,
            targetAmountPennies: goal.targetAmountPennies,
            createdAt: goal.createdAt,
            completedAt: goal.completedAt,
            isArchived: goal.isArchived,
            targetDate: goal.targetDate,
            linkURL: goal.linkURL,
            imageURL: goal.imageURL
        )
        applySystemFields(from: goal)
    }

    // MARK: - CacheMergeable

    func update(from goal: Goal, isServerSync: Bool = false) {
        profileRecordName = goal.profile.recordID.recordName
        familyRecordName = goal.family.recordID.recordName
        bucketKind = goal.bucketKind
        name = goal.name
        category = goal.category
        emojiIcon = goal.emojiIcon
        targetAmountPennies = goal.targetAmountPennies
        createdAt = goal.createdAt
        completedAt = goal.completedAt
        isArchived = goal.isArchived
        targetDate = goal.targetDate
        linkURL = goal.linkURL
        imageURL = goal.imageURL
        applySystemFields(from: goal, isServerSync: isServerSync)
    }

    static func fetchDescriptor(familyRecordName: String?) -> FetchDescriptor<GoalCache> {
        if let familyRecordName {
            return FetchDescriptor<GoalCache>(predicate: #Predicate { $0.familyRecordName == familyRecordName })
        }
        return FetchDescriptor<GoalCache>()
    }

    static func fetchDescriptor(recordName: String) -> FetchDescriptor<GoalCache> {
        FetchDescriptor<GoalCache>(predicate: #Predicate { $0.recordName == recordName })
    }

    static func fetchDescriptor(recordName: String, familyRecordName: String) -> FetchDescriptor<GoalCache> {
        FetchDescriptor<GoalCache>(predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == familyRecordName })
    }

    // MARK: - Family Predicates

    /// WHY single source: views share the family isolation boundary so store filtering never drifts.
    static func familyPredicate(familyRecordName: String) -> Predicate<GoalCache> {
        let targetFamily = familyRecordName
        return #Predicate<GoalCache> { $0.familyRecordName == targetFamily }
    }

    /// WHY single source: hero-scoped reads push family+profile to the store instead of scanning.
    static func profilePredicate(familyRecordName: String, profileRecordName: String) -> Predicate<GoalCache> {
        let targetFamily = familyRecordName
        let targetProfile = profileRecordName
        return #Predicate<GoalCache> {
            $0.familyRecordName == targetFamily && $0.profileRecordName == targetProfile
        }
    }
}
