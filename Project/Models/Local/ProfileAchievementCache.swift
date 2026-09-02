//
//  ProfileAchievementCache.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import SwiftData

@Model
final class ProfileAchievementCache: FamilyScopedCache, CacheMergeable {
    typealias DomainModel = ProfileAchievement

    #Index<ProfileAchievementCache>([\.familyRecordName, \.recordName], [\.familyRecordName, \.profileRecordName, \.earnedDate])

    var recordName: String
    var achievementRecordName: String
    var profileRecordName: String
    var familyRecordName: String
    var earnedDate: Date
    var changeTag: String?
    var encodedSystemFields: Data?
    var sourceZoneName: String?
    var sourceZoneOwnerName: String?
    var sourceDatabaseScope: String?

    init(recordName: String,
         achievementRecordName: String,
         profileRecordName: String,
         familyRecordName: String,
         earnedDate: Date,
         changeTag: String? = nil,
         encodedSystemFields: Data? = nil,
         sourceZoneName: String? = nil,
         sourceZoneOwnerName: String? = nil,
         sourceDatabaseScope: String? = nil)
    {
        self.recordName = recordName
        self.achievementRecordName = achievementRecordName
        self.profileRecordName = profileRecordName
        self.familyRecordName = familyRecordName
        self.earnedDate = earnedDate
        self.changeTag = changeTag
        self.encodedSystemFields = encodedSystemFields
        self.sourceZoneName = sourceZoneName
        self.sourceZoneOwnerName = sourceZoneOwnerName
        self.sourceDatabaseScope = sourceDatabaseScope
    }

    convenience init(from pa: ProfileAchievement) {
        self.init(
            recordName: pa.id.recordName,
            achievementRecordName: pa.achievement.recordID.recordName,
            profileRecordName: pa.profile.recordID.recordName,
            familyRecordName: pa.family.recordID.recordName,
            earnedDate: pa.earnedDate,
            changeTag: pa.changeTag,
            encodedSystemFields: pa.encodedSystemFields,
            sourceZoneName: pa.id.zoneID.zoneName,
            sourceZoneOwnerName: pa.id.zoneID.ownerName,
            sourceDatabaseScope: inferDatabaseScope(from: pa.id.zoneID)
        )
    }

    // MARK: - CacheMergeable

    func update(from pa: ProfileAchievement, isServerSync: Bool = false) {
        achievementRecordName = pa.achievement.recordID.recordName
        profileRecordName = pa.profile.recordID.recordName
        familyRecordName = pa.family.recordID.recordName
        earnedDate = pa.earnedDate
        changeTag = pa.changeTag
        sourceZoneName = pa.id.zoneID.zoneName
        sourceZoneOwnerName = pa.id.zoneID.ownerName
        sourceDatabaseScope = inferDatabaseScope(from: pa.id.zoneID)
        if isServerSync, pa.encodedSystemFields != nil {
            encodedSystemFields = pa.encodedSystemFields
        }
    }

    static func fetchDescriptor(familyRecordName: String?) -> FetchDescriptor<ProfileAchievementCache> {
        if let familyRecordName {
            return FetchDescriptor<ProfileAchievementCache>(predicate: #Predicate { $0.familyRecordName == familyRecordName })
        }
        return FetchDescriptor<ProfileAchievementCache>()
    }

    static func fetchDescriptor(recordName: String) -> FetchDescriptor<ProfileAchievementCache> {
        FetchDescriptor<ProfileAchievementCache>(predicate: #Predicate { $0.recordName == recordName })
    }

    static func fetchDescriptor(recordName: String, familyRecordName: String) -> FetchDescriptor<ProfileAchievementCache> {
        FetchDescriptor<ProfileAchievementCache>(predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == familyRecordName })
    }
}
