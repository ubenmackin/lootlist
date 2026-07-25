//
//  ProfileAchievementCache.swift
//  LootList
//
//  Created for Local-First SwiftData Architecture.
//

import Foundation
import SwiftData

@Model
final class ProfileAchievementCache {
    @Attribute(.unique) var recordName: String
    var achievementRecordName: String
    var profileRecordName: String
    var familyRecordName: String
    var earnedDate: Date

    init(recordName: String,
         achievementRecordName: String,
         profileRecordName: String,
         familyRecordName: String,
         earnedDate: Date)
    {
        self.recordName = recordName
        self.achievementRecordName = achievementRecordName
        self.profileRecordName = profileRecordName
        self.familyRecordName = familyRecordName
        self.earnedDate = earnedDate
    }

    convenience init(from pa: ProfileAchievement) {
        self.init(
            recordName: pa.id.recordName,
            achievementRecordName: pa.achievement.recordID.recordName,
            profileRecordName: pa.profile.recordID.recordName,
            familyRecordName: pa.family.recordID.recordName,
            earnedDate: pa.earnedDate
        )
    }
}
