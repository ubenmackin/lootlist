//
//  ProfileCache.swift
//  LootList
//
//

import Foundation
import SwiftData

@Model
final class ProfileCache {
    #Index<ProfileCache>([\.familyRecordName], [\.iCloudUserRecordName])

    @Attribute(.unique) var recordName: String
    var familyRecordName: String
    var displayName: String
    var role: String
    var xpTotal: Int
    var avatarName: String?
    @Attribute(.externalStorage) var customAvatarImageData: Data?
    var isActive: Bool
    var level: Int
    var iCloudUserRecordName: String
    var avatarClass: String?
    var payoutPolicy: String

    init(recordName: String,
         familyRecordName: String,
         displayName: String,
         role: String,
         xpTotal: Int,
         avatarName: String?,
         customAvatarImageData: Data? = nil,
         isActive: Bool,
         level: Int,
         iCloudUserRecordName: String,
         avatarClass: String?,
         payoutPolicy: String)
    {
        self.recordName = recordName
        self.familyRecordName = familyRecordName
        self.displayName = displayName
        self.role = role
        self.xpTotal = xpTotal
        self.avatarName = avatarName
        self.customAvatarImageData = customAvatarImageData
        self.isActive = isActive
        self.level = level
        self.iCloudUserRecordName = iCloudUserRecordName
        self.avatarClass = avatarClass
        self.payoutPolicy = payoutPolicy
    }

    convenience init(from profile: Profile) {
        self.init(
            recordName: profile.id.recordName,
            familyRecordName: profile.family.recordID.recordName,
            displayName: profile.displayName,
            role: profile.role.rawValue,
            xpTotal: profile.xp,
            avatarName: profile.avatarPresetID,
            customAvatarImageData: profile.customAvatarImageData,
            isActive: profile.isActive,
            level: profile.level,
            iCloudUserRecordName: profile.iCloudUserID.recordName,
            avatarClass: profile.avatarClass?.rawValue,
            payoutPolicy: profile.payoutPolicy.rawValue
        )
    }
}
