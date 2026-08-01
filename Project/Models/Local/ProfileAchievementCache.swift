//
//  ProfileAchievementCache.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation
import SwiftData

@Model
final class ProfileAchievementCache: FamilyScopedCache, CacheMergeable {
    typealias DomainModel = ProfileAchievement

    #Index<ProfileAchievementCache>([\.familyRecordName, \.profileRecordName, \.earnedDate])

    @Attribute(.unique) var recordName: String
    var achievementRecordName: String
    var profileRecordName: String
    var familyRecordName: String
    var earnedDate: Date
    var changeTag: String?

    init(recordName: String,
         achievementRecordName: String,
         profileRecordName: String,
         familyRecordName: String,
         earnedDate: Date,
         changeTag: String? = nil)
    {
        self.recordName = recordName
        self.achievementRecordName = achievementRecordName
        self.profileRecordName = profileRecordName
        self.familyRecordName = familyRecordName
        self.earnedDate = earnedDate
        self.changeTag = changeTag
    }

    convenience init(from pa: ProfileAchievement) {
        self.init(
            recordName: pa.id.recordName,
            achievementRecordName: pa.achievement.recordID.recordName,
            profileRecordName: pa.profile.recordID.recordName,
            familyRecordName: pa.family.recordID.recordName,
            earnedDate: pa.earnedDate,
            changeTag: pa.changeTag
        )
    }

    // MARK: - CacheMergeable

    func update(from pa: ProfileAchievement) {
        achievementRecordName = pa.achievement.recordID.recordName
        profileRecordName = pa.profile.recordID.recordName
        familyRecordName = pa.family.recordID.recordName
        earnedDate = pa.earnedDate
        changeTag = pa.changeTag
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
}
