//
//  NotificationPreferenceCache.swift
//  LootList
//

import Foundation
import SwiftData

@Model
final class NotificationPreferenceCache {
    #Index<NotificationPreferenceCache>([\.profileRecordName])

    @Attribute(.unique) var recordName: String
    var profileRecordName: String
    var familyRecordName: String
    var eventType: String
    var enabled: Bool
    var pushEnabled: Bool

    init(recordName: String,
         profileRecordName: String,
         familyRecordName: String,
         eventType: String,
         enabled: Bool,
         pushEnabled: Bool)
    {
        self.recordName = recordName
        self.profileRecordName = profileRecordName
        self.familyRecordName = familyRecordName
        self.eventType = eventType
        self.enabled = enabled
        self.pushEnabled = pushEnabled
    }

    convenience init(from preference: NotificationPreference) {
        self.init(
            recordName: preference.id.recordName,
            profileRecordName: preference.profile.recordID.recordName,
            familyRecordName: preference.family.recordID.recordName,
            eventType: preference.eventType.rawValue,
            enabled: preference.enabled,
            pushEnabled: preference.pushEnabled
        )
    }
}
