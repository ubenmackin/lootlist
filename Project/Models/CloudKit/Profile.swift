//
//  Profile.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation

struct Profile: Identifiable, Equatable, Sendable {
    static let recordType: String = "Profile"

    let id: CKRecord.ID

    /// Server-owned CloudKit change tag captured on read for cache-staleness
    /// checks. Not authored locally — `toRecord()` does not stamp this field.
    var changeTag: String?

    /// Serialized CloudKit system fields (metadata, change tag, dates) to avoid
    /// conflict loops when sending updates via CKSyncEngine.
    var encodedSystemFields: Data?

    var displayName: String
    var avatarClass: AvatarClass?
    var avatarPresetID: String?
    var customAvatarImageData: Data?
    var role: UserRole
    var xp: Int
    var level: Int
    var gems: Int
    var streakShields: Int
    var mascotCompanion: String?

    /// The profile's bound iCloud identity. This is derived from CloudKit's
    /// server-stamped creator identity when the record is decoded and is not
    /// mutable through an existing profile instance.
    let iCloudUserID: CKRecord.ID

    /// CloudKit's read-only creator identity for this profile. A nil value is
    /// an unanchored legacy/local model and must not be used for session
    /// recovery or identity-sensitive discovery.
    let creatorUserRecordName: String?

    var family: CKRecord.Reference

    var isActive: Bool
    var payoutPolicy: PayoutPolicy
    var payoutDay: PayoutDay?

    // MARK: - Gamification claim state (CloudKit-backed, never UserDefaults)

    /// These fields replace device-local UserDefaults/AppStorage so claim guards
    /// and counters sync cross-device and cannot be forged by editing the
    /// UserDefaults plist. See ARCHITECTURE.md §2 UserDefaults Policy.
    /// Catalog item IDs this hero owns (idempotent ownership ledger; union-merged on conflict).
    var ownedEquipment: [String]
    /// Catalog item IDs currently equipped (at most one per `ShopCategory`; client-wins display).
    var equippedItems: [String]
    /// `yyyy-MM-dd` of the last claimed daily-login reward (cross-device claim guard).
    var dailyLoginLastClaimDay: String?
    /// 1...7 position in the rotating daily-reward cycle.
    var dailyLoginCycleDay: Int
    /// Consecutive-day streak count; drives the XP streak multiplier (never read from UserDefaults).
    var dailyLoginStreakDays: Int
    /// Objective IDs (`{date}-{type}`) already claimed; cross-device multi-claim guard.
    var claimedBonusObjectives: [String]

    var effectiveClassDisplay: String {
        if let avatarClass {
            avatarClass.displayName
        } else {
            role.genericRoleName
        }
    }

    /// Applies cache-backed profile values without replacing the server-owned
    /// identity or family binding held by the current session.
    func mergingCacheValues(from cached: Profile) -> Profile {
        var merged = self
        merged.changeTag = cached.changeTag
        merged.encodedSystemFields = cached.encodedSystemFields
        merged.displayName = cached.displayName
        merged.avatarClass = cached.avatarClass
        merged.avatarPresetID = cached.avatarPresetID
        merged.customAvatarImageData = cached.customAvatarImageData
        merged.role = cached.role
        merged.xp = cached.xp
        merged.level = cached.level
        merged.gems = cached.gems
        merged.streakShields = cached.streakShields
        merged.mascotCompanion = cached.mascotCompanion
        merged.isActive = cached.isActive
        merged.payoutPolicy = cached.payoutPolicy
        merged.payoutDay = cached.payoutDay
        merged.ownedEquipment = cached.ownedEquipment
        merged.equippedItems = cached.equippedItems
        merged.dailyLoginLastClaimDay = cached.dailyLoginLastClaimDay
        merged.dailyLoginCycleDay = cached.dailyLoginCycleDay
        merged.dailyLoginStreakDays = cached.dailyLoginStreakDays
        merged.claimedBonusObjectives = cached.claimedBonusObjectives
        return merged
    }

    init(record: CKRecord) throws {
        guard record.recordType == Self.recordType else {
            throw CKDecodingError.unexpectedRecordType(expected: Self.recordType,
                                                       actual: record.recordType)
        }
        id = record.recordID
        changeTag = record.recordChangeTag
        encodedSystemFields = record.encodedSystemFields

        displayName = try record.extract("displayName")

        if let avatarClassRaw: String = record.extractOptional("avatarClass") {
            avatarClass = AvatarClass(rawValue: avatarClassRaw)
        } else {
            avatarClass = nil
        }

        avatarPresetID = record.extractOptional("avatarPresetID")
        customAvatarImageData = record.extractOptional("customAvatarImageData")

        guard let roleRaw: String = record.extractOptional("role"),
              let role = UserRole(rawValue: roleRaw)
        else {
            throw CKDecodingError.missingField("role")
        }
        self.role = role

        xp = try record.extract("xp")
        level = try record.extract("level")
        gems = record.extractOptional("gems") ?? 0
        streakShields = record.extractOptional("streakShields") ?? 0
        mascotCompanion = record.extractOptional("mascotCompanion")

        let iCloudUserIDStr: String = try record.extract("iCloudUserID")
        creatorUserRecordName = record.creatorUserRecordID?.recordName
        if let creatorUserRecordName,
           creatorUserRecordName != CKCurrentUserDefaultName,
           creatorUserRecordName != "_defaultOwner_"
        {
            // `iCloudUserID` is a legacy mutable field on the wire. Once
            // CloudKit has stamped the record, its creator is the only
            // authoritative profile-to-user binding.
            iCloudUserID = CKRecord.ID(recordName: creatorUserRecordName)
        } else {
            iCloudUserID = CKRecord.ID(recordName: iCloudUserIDStr)
        }

        guard let familyRef = record["family"] as? CKRecord.Reference else {
            throw CKDecodingError.missingField("family")
        }
        family = familyRef

        isActive = record.bool(forKey: "isActive", default: false)

        if let rawPolicy: String = record.extractOptional("payoutPolicy"),
           let policy = PayoutPolicy(rawValue: rawPolicy)
        {
            payoutPolicy = policy
        } else {
            payoutPolicy = .perQuest
        }

        if let rawDay: String = record.extractOptional("payoutDay"),
           let day = PayoutDay(rawValue: rawDay)
        {
            payoutDay = day
        } else {
            payoutDay = nil
        }

        // Gamification claim state — CloudKit-backed so it syncs cross-device
        // and survives UserDefaults plist editing. Arrays/Ints default safely
        // for legacy records that predate these fields.
        ownedEquipment = record.extractOptional("ownedEquipment") ?? []
        equippedItems = record.extractOptional("equippedItems") ?? []
        dailyLoginLastClaimDay = record.extractOptional("dailyLoginLastClaimDay")
        dailyLoginCycleDay = record.extractOptional("dailyLoginCycleDay") ?? 1
        dailyLoginStreakDays = record.extractOptional("dailyLoginStreakDays") ?? 0
        claimedBonusObjectives = record.extractOptional("claimedBonusObjectives") ?? []
    }

    func toRecord() -> CKRecord {
        let record = CKRecord.from(systemFields: encodedSystemFields, fallbackType: Self.recordType, fallbackID: id)
        record["displayName"] = displayName as CKRecordValue
        if let avatarClass {
            record["avatarClass"] = avatarClass.rawValue as CKRecordValue
        } else {
            record["avatarClass"] = nil
        }
        if let avatarPresetID {
            record["avatarPresetID"] = avatarPresetID as CKRecordValue
        } else {
            record["avatarPresetID"] = nil
        }
        if let customAvatarImageData {
            record["customAvatarImageData"] = customAvatarImageData as CKRecordValue
        } else {
            record["customAvatarImageData"] = nil
        }
        record["role"] = role.rawValue as CKRecordValue
        record["xp"] = xp as CKRecordValue
        record["level"] = level as CKRecordValue
        record["gems"] = gems as CKRecordValue
        record["streakShields"] = streakShields as CKRecordValue
        if let mascotCompanion {
            record["mascotCompanion"] = mascotCompanion as CKRecordValue
        } else {
            record["mascotCompanion"] = nil
        }
        // New profiles need the field to establish the initial binding. For an
        // existing profile, always serialize the server-stamped creator value
        // rather than a caller-provided mutable copy.
        let boundUserRecordName: String = if let creatorUserRecordName,
                                             creatorUserRecordName != CKCurrentUserDefaultName,
                                             creatorUserRecordName != "_defaultOwner_"
        {
            creatorUserRecordName
        } else {
            iCloudUserID.recordName
        }
        record["iCloudUserID"] = boundUserRecordName as CKRecordValue
        record["family"] = family as CKRecordValue
        record["isActive"] = isActive as CKRecordValue
        record["payoutPolicy"] = payoutPolicy.rawValue as CKRecordValue
        if let payoutDay {
            record["payoutDay"] = payoutDay.rawValue as CKRecordValue
        } else {
            record["payoutDay"] = nil
        }
        // Gamification claim state. CloudKit rejects initializing a field with
        // an empty list, so omit empty arrays (managed-field clearing in
        // RecordBridge.prepareRecord nils them server-side).
        if !ownedEquipment.isEmpty {
            record["ownedEquipment"] = ownedEquipment as CKRecordValue
        }
        if !equippedItems.isEmpty {
            record["equippedItems"] = equippedItems as CKRecordValue
        }
        if let dailyLoginLastClaimDay {
            record["dailyLoginLastClaimDay"] = dailyLoginLastClaimDay as CKRecordValue
        } else {
            record["dailyLoginLastClaimDay"] = nil
        }
        record["dailyLoginCycleDay"] = dailyLoginCycleDay as CKRecordValue
        record["dailyLoginStreakDays"] = dailyLoginStreakDays as CKRecordValue
        if !claimedBonusObjectives.isEmpty {
            record["claimedBonusObjectives"] = claimedBonusObjectives as CKRecordValue
        }
        return record
    }

    init(displayName: String,
         avatarClass: AvatarClass? = nil,
         avatarPresetID: String? = nil,
         customAvatarImageData: Data? = nil,
         role: UserRole,
         iCloudUserID: CKRecord.ID,
         creatorUserRecordName: String? = nil,
         family: CKRecord.Reference,
         payoutPolicy: PayoutPolicy = .perQuest,
         payoutDay: PayoutDay? = nil,
         gems: Int = 0,
         streakShields: Int = 0,
         mascotCompanion: String? = nil,
         ownedEquipment: [String] = [],
         equippedItems: [String] = [],
         dailyLoginLastClaimDay: String? = nil,
         dailyLoginCycleDay: Int = 1,
         dailyLoginStreakDays: Int = 0,
         claimedBonusObjectives: [String] = [],
         id: CKRecord.ID = CKRecord.ID(recordName: UUID().uuidString))
    {
        self.id = id
        self.displayName = displayName
        self.avatarClass = avatarClass
        self.avatarPresetID = avatarPresetID
        self.customAvatarImageData = customAvatarImageData
        self.role = role
        xp = 0
        level = 1
        self.gems = gems
        self.streakShields = streakShields
        self.mascotCompanion = mascotCompanion
        self.iCloudUserID = iCloudUserID
        self.creatorUserRecordName = creatorUserRecordName
        self.family = family
        isActive = true
        self.payoutPolicy = payoutPolicy
        self.payoutDay = payoutDay
        self.ownedEquipment = ownedEquipment
        self.equippedItems = equippedItems
        self.dailyLoginLastClaimDay = dailyLoginLastClaimDay
        self.dailyLoginCycleDay = dailyLoginCycleDay
        self.dailyLoginStreakDays = dailyLoginStreakDays
        self.claimedBonusObjectives = claimedBonusObjectives
    }

    /// Reconstructs the server-authenticated identity that CloudKit supplies
    /// through system fields when a record is read. The identity is not
    /// serialized by `toRecord()` and therefore cannot author or rewrite the
    /// CloudKit creator stamp.
    func applyingServerCreator(_ creatorUserRecordName: String) -> Profile {
        guard creatorUserRecordName != CKCurrentUserDefaultName,
              creatorUserRecordName != "_defaultOwner_"
        else {
            return self
        }

        var stamped = Profile(
            displayName: displayName,
            avatarClass: avatarClass,
            avatarPresetID: avatarPresetID,
            customAvatarImageData: customAvatarImageData,
            role: role,
            iCloudUserID: CKRecord.ID(recordName: creatorUserRecordName),
            creatorUserRecordName: creatorUserRecordName,
            family: family,
            payoutPolicy: payoutPolicy,
            payoutDay: payoutDay,
            gems: gems,
            streakShields: streakShields,
            mascotCompanion: mascotCompanion,
            ownedEquipment: ownedEquipment,
            equippedItems: equippedItems,
            dailyLoginLastClaimDay: dailyLoginLastClaimDay,
            dailyLoginCycleDay: dailyLoginCycleDay,
            dailyLoginStreakDays: dailyLoginStreakDays,
            claimedBonusObjectives: claimedBonusObjectives,
            id: id
        )
        stamped.xp = xp
        stamped.level = level
        stamped.isActive = isActive
        stamped.changeTag = changeTag
        stamped.encodedSystemFields = encodedSystemFields
        return stamped
    }
}

extension Profile: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
