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
    var changeTag: String?
    var encodedSystemFields: Data?
    var sourceZoneName: String?
    var sourceZoneOwnerName: String?
    var sourceDatabaseScope: String?

    var bucketKindEnum: BucketKind? {
        BucketKind(rawValue: bucketKind)
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
            changeTag: goal.changeTag,
            encodedSystemFields: goal.encodedSystemFields,
            sourceZoneName: goal.id.zoneID.zoneName,
            sourceZoneOwnerName: goal.id.zoneID.ownerName,
            sourceDatabaseScope: inferDatabaseScope(from: goal.id.zoneID)
        )
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
        changeTag = goal.changeTag
        sourceZoneName = goal.id.zoneID.zoneName
        sourceZoneOwnerName = goal.id.zoneID.ownerName
        sourceDatabaseScope = inferDatabaseScope(from: goal.id.zoneID)
        if isServerSync, goal.encodedSystemFields != nil {
            encodedSystemFields = goal.encodedSystemFields
        }
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
}
