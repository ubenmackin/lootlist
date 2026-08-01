//
//  ProfileCache.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation
import SwiftData

@Model
final class ProfileCache: FamilyScopedCache, CacheMergeable {
    typealias DomainModel = Profile

    #Index<ProfileCache>([\.familyRecordName, \.iCloudUserRecordName])

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
    var changeTag: String?

    var roleEnum: UserRole? {
        UserRole(rawValue: role)
    }

    var avatarClassEnum: AvatarClass? {
        avatarClass.flatMap { AvatarClass(rawValue: $0) }
    }

    var payoutPolicyEnum: PayoutPolicy? {
        PayoutPolicy(rawValue: payoutPolicy)
    }

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
         payoutPolicy: String,
         changeTag: String? = nil)
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
        self.changeTag = changeTag
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
            payoutPolicy: profile.payoutPolicy.rawValue,
            changeTag: profile.changeTag
        )
    }

    // MARK: - CacheMergeable

    func update(from profile: Profile) {
        familyRecordName = profile.family.recordID.recordName
        displayName = profile.displayName
        role = profile.role.rawValue
        xpTotal = profile.xp
        avatarName = profile.avatarPresetID
        customAvatarImageData = profile.customAvatarImageData
        isActive = profile.isActive
        level = profile.level
        iCloudUserRecordName = profile.iCloudUserID.recordName
        avatarClass = profile.avatarClass?.rawValue
        payoutPolicy = profile.payoutPolicy.rawValue
        changeTag = profile.changeTag
    }

    static func fetchDescriptor(familyRecordName: String?) -> FetchDescriptor<ProfileCache> {
        if let familyRecordName {
            return FetchDescriptor<ProfileCache>(predicate: #Predicate { $0.familyRecordName == familyRecordName })
        }
        return FetchDescriptor<ProfileCache>()
    }

    static func fetchDescriptor(recordName: String) -> FetchDescriptor<ProfileCache> {
        FetchDescriptor<ProfileCache>(predicate: #Predicate { $0.recordName == recordName })
    }
}
