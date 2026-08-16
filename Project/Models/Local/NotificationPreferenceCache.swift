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
    @Attribute(.externalStorage) var encodedSystemFields: Data?
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
            enabled: preference.enabled,
            changeTag: preference.changeTag,
            encodedSystemFields: preference.encodedSystemFields,
            sourceZoneName: preference.id.zoneID.zoneName,
            sourceZoneOwnerName: preference.id.zoneID.ownerName,
            sourceDatabaseScope: inferDatabaseScope(from: preference.id.zoneID)
        )
    }

    // MARK: - CacheMergeable

    func update(from preference: NotificationPreference, isServerSync: Bool = false) {
        profileRecordName = preference.profile.recordID.recordName
        familyRecordName = preference.family.recordID.recordName
        eventType = preference.eventType.rawValue
        enabled = preference.enabled
        changeTag = preference.changeTag
        sourceZoneName = preference.id.zoneID.zoneName
        sourceZoneOwnerName = preference.id.zoneID.ownerName
        sourceDatabaseScope = inferDatabaseScope(from: preference.id.zoneID)
        if isServerSync, preference.encodedSystemFields != nil {
            encodedSystemFields = preference.encodedSystemFields
        }
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
}
