//
//  NotificationPreferenceCache.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import SwiftData

@Model
final class NotificationPreferenceCache: FamilyScopedCache, CacheMergeable {
    typealias DomainModel = NotificationPreference

    #Index<NotificationPreferenceCache>([\.familyRecordName, \.recordName], [\.familyRecordName, \.profileRecordName, \.eventType])

    var recordName: String
    var profileRecordName: String
    var familyRecordName: String
    var eventType: String
    var enabled: Bool
    var changeTag: String?
    var encodedSystemFields: Data?
    var sourceZoneName: String?
    var sourceZoneOwnerName: String?
    var sourceDatabaseScope: String?

    var eventTypeEnum: NotificationEventType? {
        NotificationEventType(rawValue: eventType)
    }

    init(recordName: String,
         profileRecordName: String,
         familyRecordName: String,
         eventType: String,
         enabled: Bool,
         changeTag: String? = nil,
         encodedSystemFields: Data? = nil,
         sourceZoneName: String? = nil,
         sourceZoneOwnerName: String? = nil,
         sourceDatabaseScope: String? = nil)
    {
        self.recordName = recordName
        self.profileRecordName = profileRecordName
        self.familyRecordName = familyRecordName
        self.eventType = eventType
        self.enabled = enabled
        self.changeTag = changeTag
        self.encodedSystemFields = encodedSystemFields
        self.sourceZoneName = sourceZoneName
        self.sourceZoneOwnerName = sourceZoneOwnerName
        self.sourceDatabaseScope = sourceDatabaseScope
    }

    convenience init(from preference: NotificationPreference) {
        self.init(
            recordName: preference.id.recordName,
            profileRecordName: preference.profile.recordID.recordName,
            familyRecordName: preference.family.recordID.recordName,
            eventType: preference.eventType.rawValue,
            enabled: preference.enabled
        )
        applySystemFields(from: preference)
    }

    // MARK: - CacheMergeable

    func update(from preference: NotificationPreference, isServerSync: Bool = false) {
        profileRecordName = preference.profile.recordID.recordName
        familyRecordName = preference.family.recordID.recordName
        eventType = preference.eventType.rawValue
        enabled = preference.enabled
        applySystemFields(from: preference, isServerSync: isServerSync)
    }

    static func fetchDescriptor(familyRecordName: String?) -> FetchDescriptor<NotificationPreferenceCache> {
        if let familyRecordName {
            return FetchDescriptor<NotificationPreferenceCache>(predicate: #Predicate { $0.familyRecordName == familyRecordName })
        }
        return FetchDescriptor<NotificationPreferenceCache>()
    }

    static func fetchDescriptor(recordName: String) -> FetchDescriptor<NotificationPreferenceCache> {
        FetchDescriptor<NotificationPreferenceCache>(predicate: #Predicate { $0.recordName == recordName })
    }

    static func fetchDescriptor(recordName: String, familyRecordName: String) -> FetchDescriptor<NotificationPreferenceCache> {
        FetchDescriptor<NotificationPreferenceCache>(predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == familyRecordName })
    }

    // MARK: - Family Predicates

    /// WHY single source: views share the family isolation boundary so store filtering never drifts.
    static func familyPredicate(familyRecordName: String) -> Predicate<NotificationPreferenceCache> {
        let targetFamily = familyRecordName
        return #Predicate<NotificationPreferenceCache> { $0.familyRecordName == targetFamily }
    }

    /// WHY single source: hero-scoped reads push family+profile to the store instead of scanning.
    static func profilePredicate(familyRecordName: String, profileRecordName: String) -> Predicate<NotificationPreferenceCache> {
        let targetFamily = familyRecordName
        let targetProfile = profileRecordName
        return #Predicate<NotificationPreferenceCache> {
            $0.familyRecordName == targetFamily && $0.profileRecordName == targetProfile
        }
    }
}
