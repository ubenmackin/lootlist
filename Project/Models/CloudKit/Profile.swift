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
    var payoutPolicy: PayoutPolicy?
    var payoutDay: PayoutDay?

    // MARK: - Gamification claim state (CloudKit-backed, never UserDefaults)

    /// Ownership ledger and streak fields synced cross-device via CloudKit.
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
    /// The highest level the hero has viewed on the Journey Map; syncs across devices so progression animation is never duplicated.
    var journeyMapLastSeenLevel: Int

    // MARK: - Savings config (V8)

    /// Emoji rendered as the profile's lightweight avatar; nil falls back to
    /// preset/sprite rendering so legacy records are unaffected.
    var avatarEmoji: String?

    /// Percentage splits applied to FUTURE payouts only — never rebalanced
    /// retroactively. Defaults route everything to spend so profiles that
    /// predate buckets keep their exact pre-V8 payout behavior.
    var splitPercentSpend: Int
    var splitPercentShort: Int
    var splitPercentLong: Int

    /// Monthly interest config. Disabled by default so no money moves until a
    /// parent explicitly turns the engine on.
    var interestEnabled: Bool
    /// Raw value of `BucketKind`; which save bucket earns the interest.
    var interestBucket: String?
    var interestRateBps: Int
    var interestIsCompound: Bool

    /// Parent-matching config for long-term goal contributions. Disabled by
    /// default for the same fail-safe reason as interest.
    var matchEnabled: Bool
    var matchRateBps: Int
    /// Monthly cap in pennies on total matched amounts; nil means uncapped.
    var matchMonthlyCapPennies: Int64?

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
        merged.journeyMapLastSeenLevel = cached.journeyMapLastSeenLevel
        merged.avatarEmoji = cached.avatarEmoji
        merged.splitPercentSpend = cached.splitPercentSpend
        merged.splitPercentShort = cached.splitPercentShort
        merged.splitPercentLong = cached.splitPercentLong
        merged.interestEnabled = cached.interestEnabled
        merged.interestBucket = cached.interestBucket
        merged.interestRateBps = cached.interestRateBps
        merged.interestIsCompound = cached.interestIsCompound
        merged.matchEnabled = cached.matchEnabled
        merged.matchRateBps = cached.matchRateBps
        merged.matchMonthlyCapPennies = cached.matchMonthlyCapPennies
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
            payoutPolicy = nil
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
        journeyMapLastSeenLevel = record.extractOptional("journeyMapLastSeenLevel") ?? 1

        // Savings config — Ints/Booleans default safely for legacy records
        // that predate these fields (same pattern as the gamification block).
        avatarEmoji = record.extractOptional("avatarEmoji")
        splitPercentSpend = record.extractOptional("splitPercentSpend") ?? 100
        splitPercentShort = record.extractOptional("splitPercentShort") ?? 0
        splitPercentLong = record.extractOptional("splitPercentLong") ?? 0
        interestEnabled = record.bool(forKey: "interestEnabled", default: false)
        interestBucket = record.extractOptional("interestBucket")
        interestRateBps = record.extractOptional("interestRateBps") ?? 0
        interestIsCompound = record.bool(forKey: "interestIsCompound", default: false)
        matchEnabled = record.bool(forKey: "matchEnabled", default: false)
        matchRateBps = record.extractOptional("matchRateBps") ?? 0
        if let capNumber = record["matchMonthlyCapPennies"] as? NSNumber {
            matchMonthlyCapPennies = capNumber.int64Value
        } else {
            matchMonthlyCapPennies = nil
        }
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
        if let payoutPolicy {
            record["payoutPolicy"] = payoutPolicy.rawValue as CKRecordValue
        } else {
            record["payoutPolicy"] = nil
        }
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
        record["journeyMapLastSeenLevel"] = journeyMapLastSeenLevel as CKRecordValue
        // Savings config. CloudKit rejects initializing a field with an empty
        // list, so optional bucket/cap values nil out explicitly instead.
        record["avatarEmoji"] = avatarEmoji as CKRecordValue?
        record["splitPercentSpend"] = splitPercentSpend as CKRecordValue
        record["splitPercentShort"] = splitPercentShort as CKRecordValue
        record["splitPercentLong"] = splitPercentLong as CKRecordValue
        record["interestEnabled"] = interestEnabled as CKRecordValue
        record["interestBucket"] = interestBucket as CKRecordValue?
        record["interestRateBps"] = interestRateBps as CKRecordValue
        record["interestIsCompound"] = interestIsCompound as CKRecordValue
        record["matchEnabled"] = matchEnabled as CKRecordValue
        record["matchRateBps"] = matchRateBps as CKRecordValue
        record["matchMonthlyCapPennies"] = matchMonthlyCapPennies as CKRecordValue?
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
         payoutPolicy: PayoutPolicy? = nil,
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
         journeyMapLastSeenLevel: Int = 1,
         avatarEmoji: String? = nil,
         splitPercentSpend: Int = 100,
         splitPercentShort: Int = 0,
         splitPercentLong: Int = 0,
         interestEnabled: Bool = false,
         interestBucket: String? = nil,
         interestRateBps: Int = 0,
         interestIsCompound: Bool = false,
         matchEnabled: Bool = false,
         matchRateBps: Int = 0,
         matchMonthlyCapPennies: Int64? = nil,
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
        self.journeyMapLastSeenLevel = journeyMapLastSeenLevel
        self.avatarEmoji = avatarEmoji
        self.splitPercentSpend = splitPercentSpend
        self.splitPercentShort = splitPercentShort
        self.splitPercentLong = splitPercentLong
        self.interestEnabled = interestEnabled
        self.interestBucket = interestBucket
        self.interestRateBps = interestRateBps
        self.interestIsCompound = interestIsCompound
        self.matchEnabled = matchEnabled
        self.matchRateBps = matchRateBps
        self.matchMonthlyCapPennies = matchMonthlyCapPennies
    }

    /// Reconstructs the server-authenticated identity that CloudKit supplies through system fields when a
    /// record is read.
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
            journeyMapLastSeenLevel: journeyMapLastSeenLevel,
            avatarEmoji: avatarEmoji,
            splitPercentSpend: splitPercentSpend,
            splitPercentShort: splitPercentShort,
            splitPercentLong: splitPercentLong,
            interestEnabled: interestEnabled,
            interestBucket: interestBucket,
            interestRateBps: interestRateBps,
            interestIsCompound: interestIsCompound,
            matchEnabled: matchEnabled,
            matchRateBps: matchRateBps,
            matchMonthlyCapPennies: matchMonthlyCapPennies,
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
