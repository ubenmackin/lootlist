//
//  RewardEventCache.swift
//  LootList
//
//  Created by Ben Mackin on 8/17/26.
//

import CloudKit
import Foundation
import SwiftData

@Model
final class RewardEventCache: FamilyScopedCache, CacheMergeable {
    typealias DomainModel = RewardEvent

    #Index<RewardEventCache>([\.familyRecordName, \.recordName], [\.familyRecordName, \.questCompletionRecordName])

    var recordName: String
    var profileRecordName: String
    var questCompletionRecordName: String
    var familyRecordName: String
    var xpAmount: Int
    var goldAmount: Double
    var timestamp: Date
    var changeTag: String?
    var encodedSystemFields: Data?
    var sourceZoneName: String?
    var sourceZoneOwnerName: String?
    var sourceDatabaseScope: String?

    init(
        recordName: String,
        profileRecordName: String,
        questCompletionRecordName: String,
        familyRecordName: String,
        xpAmount: Int,
        goldAmount: Double,
        timestamp: Date,
        changeTag: String? = nil,
        encodedSystemFields: Data? = nil,
        sourceZoneName: String? = nil,
        sourceZoneOwnerName: String? = nil,
        sourceDatabaseScope: String? = nil
    ) {
        self.recordName = recordName
        self.profileRecordName = profileRecordName
        self.questCompletionRecordName = questCompletionRecordName
        self.familyRecordName = familyRecordName
        self.xpAmount = xpAmount
        self.goldAmount = goldAmount
        self.timestamp = timestamp
        self.changeTag = changeTag
        self.encodedSystemFields = encodedSystemFields
        self.sourceZoneName = sourceZoneName
        self.sourceZoneOwnerName = sourceZoneOwnerName
        self.sourceDatabaseScope = sourceDatabaseScope
    }

    convenience init(from event: RewardEvent) {
        self.init(
            recordName: event.id.recordName,
            profileRecordName: event.profile.recordID.recordName,
            questCompletionRecordName: event.questCompletion.recordID.recordName,
            familyRecordName: event.family.recordID.recordName,
            xpAmount: event.xpAmount,
            goldAmount: event.goldAmount,
            timestamp: event.timestamp,
            changeTag: event.changeTag,
            encodedSystemFields: event.encodedSystemFields,
            sourceZoneName: event.id.zoneID.zoneName,
            sourceZoneOwnerName: event.id.zoneID.ownerName,
            sourceDatabaseScope: inferDatabaseScope(from: event.id.zoneID)
        )
    }

    func update(from event: RewardEvent, isServerSync: Bool = false) {
        profileRecordName = event.profile.recordID.recordName
        questCompletionRecordName = event.questCompletion.recordID.recordName
        familyRecordName = event.family.recordID.recordName
        xpAmount = event.xpAmount
        goldAmount = event.goldAmount
        timestamp = event.timestamp
        changeTag = event.changeTag
        sourceZoneName = event.id.zoneID.zoneName
        sourceZoneOwnerName = event.id.zoneID.ownerName
        sourceDatabaseScope = inferDatabaseScope(from: event.id.zoneID)
        if isServerSync, event.encodedSystemFields != nil {
            encodedSystemFields = event.encodedSystemFields
        }
    }

    static func fetchDescriptor(familyRecordName: String?) -> FetchDescriptor<RewardEventCache> {
        if let familyRecordName {
            return FetchDescriptor<RewardEventCache>(predicate: #Predicate { $0.familyRecordName == familyRecordName })
        }
        return FetchDescriptor<RewardEventCache>()
    }

    static func fetchDescriptor(recordName: String) -> FetchDescriptor<RewardEventCache> {
        FetchDescriptor<RewardEventCache>(predicate: #Predicate { $0.recordName == recordName })
    }

    static func fetchDescriptor(recordName: String, familyRecordName: String) -> FetchDescriptor<RewardEventCache> {
        FetchDescriptor<RewardEventCache>(predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == familyRecordName })
    }
}
