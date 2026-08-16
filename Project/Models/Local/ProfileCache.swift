//
//  ProfileCache.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import SwiftData

@Model
final class ProfileCache: FamilyScopedCache, CacheMergeable {
    typealias DomainModel = Profile

    #Index<ProfileCache>([\.familyRecordName, \.recordName], [\.familyRecordName, \.iCloudUserRecordName])

    var recordName: String
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
    var payoutDay: String?
    var changeTag: String?
    /// Baseline server XP tracked to merge concurrent offline additions additively.
    var lastSyncedXP: Int = 0
    @Attribute(.externalStorage) var encodedSystemFields: Data?
    var sourceZoneName: String?
    var sourceZoneOwnerName: String?
    var sourceDatabaseScope: String?

    var roleEnum: UserRole? {
        UserRole(rawValue: role)
    }

    var avatarClassEnum: AvatarClass? {
        avatarClass.flatMap { AvatarClass(rawValue: $0) }
    }

    var payoutPolicyEnum: PayoutPolicy? {
        PayoutPolicy(rawValue: payoutPolicy)
    }

    var payoutDayEnum: PayoutDay? {
        payoutDay.flatMap { PayoutDay(rawValue: $0) }
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
         payoutDay: String? = nil,
         changeTag: String? = nil,
         lastSyncedXP: Int = 0,
         encodedSystemFields: Data? = nil,
         sourceZoneName: String? = nil,
         sourceZoneOwnerName: String? = nil,
         sourceDatabaseScope: String? = nil)
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
        self.payoutDay = payoutDay
        self.changeTag = changeTag
        self.lastSyncedXP = lastSyncedXP
        self.encodedSystemFields = encodedSystemFields
        self.sourceZoneName = sourceZoneName
        self.sourceZoneOwnerName = sourceZoneOwnerName
        self.sourceDatabaseScope = sourceDatabaseScope
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
            payoutDay: profile.payoutDay?.rawValue,
            changeTag: profile.changeTag,
            lastSyncedXP: profile.xp,
            encodedSystemFields: profile.encodedSystemFields,
            sourceZoneName: profile.id.zoneID.zoneName,
            sourceZoneOwnerName: profile.id.zoneID.ownerName,
            sourceDatabaseScope: inferDatabaseScope(from: profile.id.zoneID)
        )
    }

    // MARK: - CacheMergeable

    func update(from profile: Profile, isServerSync: Bool = false) {
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
        payoutDay = profile.payoutDay?.rawValue
        changeTag = profile.changeTag
        sourceZoneName = profile.id.zoneID.zoneName
        sourceZoneOwnerName = profile.id.zoneID.ownerName
        sourceDatabaseScope = inferDatabaseScope(from: profile.id.zoneID)
        if isServerSync {
            lastSyncedXP = profile.xp
            if profile.encodedSystemFields != nil {
                encodedSystemFields = profile.encodedSystemFields
            }
        }
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
