//
//  NotificationPreferenceCache.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation
import SwiftData

@Model
final class NotificationPreferenceCache: FamilyScopedCache, CacheMergeable {
    typealias DomainModel = NotificationPreference

    #Index<NotificationPreferenceCache>([\.familyRecordName, \.profileRecordName, \.eventType])

    @Attribute(.unique) var recordName: String
    var profileRecordName: String
    var familyRecordName: String
    var eventType: String
    var enabled: Bool
    var pushEnabled: Bool
    var changeTag: String?

    var eventTypeEnum: NotificationEventType? {
        NotificationEventType(rawValue: eventType)
    }

    init(recordName: String,
         profileRecordName: String,
         familyRecordName: String,
         eventType: String,
         enabled: Bool,
         pushEnabled: Bool,
         changeTag: String? = nil)
    {
        self.recordName = recordName
        self.profileRecordName = profileRecordName
        self.familyRecordName = familyRecordName
        self.eventType = eventType
        self.enabled = enabled
        self.pushEnabled = pushEnabled
        self.changeTag = changeTag
    }

    convenience init(from preference: NotificationPreference) {
        self.init(
            recordName: preference.id.recordName,
            profileRecordName: preference.profile.recordID.recordName,
            familyRecordName: preference.family.recordID.recordName,
            eventType: preference.eventType.rawValue,
            enabled: preference.enabled,
            pushEnabled: preference.pushEnabled,
            changeTag: preference.changeTag
        )
    }

    // MARK: - CacheMergeable

    func update(from preference: NotificationPreference) {
        profileRecordName = preference.profile.recordID.recordName
        familyRecordName = preference.family.recordID.recordName
        eventType = preference.eventType.rawValue
        enabled = preference.enabled
        pushEnabled = preference.pushEnabled
        changeTag = preference.changeTag
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
