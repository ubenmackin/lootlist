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
    var gemsTotal: Int = 0
    var streakShields: Int = 0
    var mascotCompanion: String?
    var iCloudUserRecordName: String
    var avatarClass: String?
    var payoutPolicy: String?
    var payoutDay: String?
    // Gamification claim state — CloudKit-backed mirrors of Profile fields.
    // Optional arrays mirror the `specificDays` pattern so legacy rows
    // (pre-dating these fields) decode as nil rather than failing migration.
    var ownedEquipment: [String]?
    var equippedItems: [String]?
    var dailyLoginLastClaimDay: String?
    var dailyLoginCycleDay: Int = 1
    var dailyLoginStreakDays: Int = 0
    var claimedBonusObjectives: [String]?
    var journeyMapLastSeenLevel: Int = 1
    var changeTag: String?
    /// Baseline server XP tracked to merge concurrent offline additions additively.
    var lastSyncedXP: Int = 0
    var encodedSystemFields: Data?
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
        payoutPolicy.flatMap { PayoutPolicy(rawValue: $0) }
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
         gemsTotal: Int = 0,
         streakShields: Int = 0,
         mascotCompanion: String? = nil,
         iCloudUserRecordName: String,
         avatarClass: String?,
         payoutPolicy: String? = nil,
         payoutDay: String? = nil,
         ownedEquipment: [String]? = nil,
         equippedItems: [String]? = nil,
         dailyLoginLastClaimDay: String? = nil,
         dailyLoginCycleDay: Int = 1,
         dailyLoginStreakDays: Int = 0,
         claimedBonusObjectives: [String]? = nil,
         journeyMapLastSeenLevel: Int = 1,
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
        self.gemsTotal = gemsTotal
        self.streakShields = streakShields
        self.mascotCompanion = mascotCompanion
        self.iCloudUserRecordName = iCloudUserRecordName
        self.avatarClass = avatarClass
        self.payoutPolicy = payoutPolicy
        self.payoutDay = payoutDay
        self.ownedEquipment = ownedEquipment
        self.equippedItems = equippedItems
        self.dailyLoginLastClaimDay = dailyLoginLastClaimDay
        self.dailyLoginCycleDay = dailyLoginCycleDay
        self.dailyLoginStreakDays = dailyLoginStreakDays
        self.claimedBonusObjectives = claimedBonusObjectives
        self.journeyMapLastSeenLevel = journeyMapLastSeenLevel
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
            gemsTotal: profile.gems,
            streakShields: profile.streakShields,
            mascotCompanion: profile.mascotCompanion,
            iCloudUserRecordName: profile.iCloudUserID.recordName,
            avatarClass: profile.avatarClass?.rawValue,
            payoutPolicy: profile.payoutPolicy?.rawValue,
            payoutDay: profile.payoutDay?.rawValue,
            ownedEquipment: profile.ownedEquipment.isEmpty ? nil : profile.ownedEquipment,
            equippedItems: profile.equippedItems.isEmpty ? nil : profile.equippedItems,
            dailyLoginLastClaimDay: profile.dailyLoginLastClaimDay,
            dailyLoginCycleDay: profile.dailyLoginCycleDay,
            dailyLoginStreakDays: profile.dailyLoginStreakDays,
            claimedBonusObjectives: profile.claimedBonusObjectives.isEmpty ? nil : profile.claimedBonusObjectives,
            journeyMapLastSeenLevel: profile.journeyMapLastSeenLevel,
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
        gemsTotal = profile.gems
        streakShields = profile.streakShields
        mascotCompanion = profile.mascotCompanion
        iCloudUserRecordName = profile.iCloudUserID.recordName
        avatarClass = profile.avatarClass?.rawValue
        payoutPolicy = profile.payoutPolicy?.rawValue
        payoutDay = profile.payoutDay?.rawValue
        ownedEquipment = profile.ownedEquipment.isEmpty ? nil : profile.ownedEquipment
        equippedItems = profile.equippedItems.isEmpty ? nil : profile.equippedItems
        dailyLoginLastClaimDay = profile.dailyLoginLastClaimDay
        dailyLoginCycleDay = profile.dailyLoginCycleDay
        dailyLoginStreakDays = profile.dailyLoginStreakDays
        claimedBonusObjectives = profile.claimedBonusObjectives.isEmpty ? nil : profile.claimedBonusObjectives
        journeyMapLastSeenLevel = profile.journeyMapLastSeenLevel
        changeTag = profile.changeTag
        sourceZoneName = profile.id.zoneID.zoneName
        sourceZoneOwnerName = profile.id.zoneID.ownerName
        sourceDatabaseScope = inferDatabaseScope(from: profile.id.zoneID)
        if isServerSync {
            // Advance baseline to prevent cumulative delta drift on next conflict.
            // Without this, clientDelta = clientXP - lastSyncedXP double-counts
            // prior deltas (Bug A). lastSyncedXP must track the last server-confirmed XP.
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
