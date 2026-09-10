//
//  SessionStorage.swift
//  LootList
//
//  Created by Ben Mackin on 9/8/26.
//

import CloudKit
import Foundation

/// WHY device-local only: session keys live in UserDefaults;
/// never authoritative domain data.
enum SessionKeys: String {
    case profileRecordName = "session_profileRecordName"
    case familyRecordName = "session_familyRecordName"
    case familyZoneName = "session_familyZoneName"
    case familyZoneOwnerName = "session_familyZoneOwnerName"
    case isZoneOwner = "session_isZoneOwner"
    case hasActiveSession = "session_hasActiveSession"
    case hasOnboarded = "session_hasOnboarded"
    case abandonedFamilyZoneNames = "session_abandonedFamilyZoneNames"
}

/// Device-local snapshot of the persisted session.
struct PersistedSession: Sendable, Equatable {
    let profileRecordName: String
    let familyRecordName: String
    let zoneID: CKRecordZone.ID
    let isZoneOwner: Bool
}

/// Typed wrapper over UserDefaults for session state.
@MainActor
final class SessionStorage {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var profileRecordName: String? {
        get { defaults.string(forKey: SessionKeys.profileRecordName.rawValue) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: SessionKeys.profileRecordName.rawValue)
            } else {
                defaults.removeObject(forKey: SessionKeys.profileRecordName.rawValue)
            }
        }
    }

    var familyRecordName: String? {
        get { defaults.string(forKey: SessionKeys.familyRecordName.rawValue) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: SessionKeys.familyRecordName.rawValue)
            } else {
                defaults.removeObject(forKey: SessionKeys.familyRecordName.rawValue)
            }
        }
    }

    var familyZoneName: String? {
        get { defaults.string(forKey: SessionKeys.familyZoneName.rawValue) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: SessionKeys.familyZoneName.rawValue)
            } else {
                defaults.removeObject(forKey: SessionKeys.familyZoneName.rawValue)
            }
        }
    }

    var familyZoneOwnerName: String? {
        get { defaults.string(forKey: SessionKeys.familyZoneOwnerName.rawValue) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: SessionKeys.familyZoneOwnerName.rawValue)
            } else {
                defaults.removeObject(forKey: SessionKeys.familyZoneOwnerName.rawValue)
            }
        }
    }

    var isZoneOwner: Bool {
        get { defaults.bool(forKey: SessionKeys.isZoneOwner.rawValue) }
        set { defaults.set(newValue, forKey: SessionKeys.isZoneOwner.rawValue) }
    }

    var hasActiveSession: Bool {
        get { defaults.bool(forKey: SessionKeys.hasActiveSession.rawValue) }
        set { defaults.set(newValue, forKey: SessionKeys.hasActiveSession.rawValue) }
    }

    var hasOnboarded: Bool {
        get { defaults.bool(forKey: SessionKeys.hasOnboarded.rawValue) }
        set { defaults.set(newValue, forKey: SessionKeys.hasOnboarded.rawValue) }
    }

    var abandonedFamilyZoneNames: [String] {
        get { defaults.stringArray(forKey: SessionKeys.abandonedFamilyZoneNames.rawValue) ?? [] }
        set { defaults.set(newValue, forKey: SessionKeys.abandonedFamilyZoneNames.rawValue) }
    }

    var hasCompletePersistedSession: Bool {
        hasActiveSession
            && profileRecordName != nil
            && familyRecordName != nil
            && familyZoneName != nil
            && familyZoneOwnerName != nil
    }

    func loadPersistedSession() -> PersistedSession? {
        guard hasActiveSession,
              let profileRecordName,
              let familyRecordName,
              let zoneName = familyZoneName,
              let zoneOwnerName = familyZoneOwnerName
        else { return nil }
        let storedOwner = isZoneOwner
        let isPlaceholder = ActiveFamilyScopeGuard.isPlaceholderOwner(zoneOwnerName)
        // WHY deny-by-default: legacy placeholder zones prove nothing about ownership.
        let resolvedOwner: Bool = isPlaceholder ? false : storedOwner
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: zoneOwnerName)
        return PersistedSession(
            profileRecordName: profileRecordName,
            familyRecordName: familyRecordName,
            zoneID: zoneID,
            isZoneOwner: resolvedOwner
        )
    }

    func save(profile: Profile, family: Family, zoneID: CKRecordZone.ID, isOwner: Bool) {
        defaults.set(profile.id.recordName, forKey: SessionKeys.profileRecordName.rawValue)
        defaults.set(family.id.recordName, forKey: SessionKeys.familyRecordName.rawValue)
        defaults.set(zoneID.zoneName, forKey: SessionKeys.familyZoneName.rawValue)
        defaults.set(zoneID.ownerName, forKey: SessionKeys.familyZoneOwnerName.rawValue)
        defaults.set(isOwner, forKey: SessionKeys.isZoneOwner.rawValue)
        defaults.set(true, forKey: SessionKeys.hasActiveSession.rawValue)
        defaults.set(true, forKey: SessionKeys.hasOnboarded.rawValue)
    }

    /// WHY preserve onboarding: a cleared session must still attempt recovery, not replay Welcome.
    func clearSessionKeys() {
        defaults.removeObject(forKey: SessionKeys.profileRecordName.rawValue)
        defaults.removeObject(forKey: SessionKeys.familyRecordName.rawValue)
        defaults.removeObject(forKey: SessionKeys.familyZoneName.rawValue)
        defaults.removeObject(forKey: SessionKeys.familyZoneOwnerName.rawValue)
        defaults.removeObject(forKey: SessionKeys.isZoneOwner.rawValue)
        defaults.removeObject(forKey: SessionKeys.hasActiveSession.rawValue)
    }

    func addAbandonedZoneID(_ zoneName: String) {
        var current = abandonedFamilyZoneNames
        if !current.contains(zoneName) {
            current.append(zoneName)
            abandonedFamilyZoneNames = current
        }
    }

    func removeAbandonedZoneID(_ zoneName: String) {
        var current = abandonedFamilyZoneNames
        current.removeAll { $0 == zoneName }
        abandonedFamilyZoneNames = current
    }
}
