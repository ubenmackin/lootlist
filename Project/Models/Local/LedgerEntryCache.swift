//
//  LedgerEntryCache.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import SwiftData

@Model
final class LedgerEntryCache: FamilyScopedCache, CacheMergeable {
    typealias DomainModel = LedgerEntry

    #Index<LedgerEntryCache>([\.familyRecordName, \.recordName], [\.familyRecordName, \.profileRecordName, \.date])

    var recordName: String
    var profileRecordName: String
    var familyRecordName: String
    var amount: Double
    var entryDescription: String
    var location: String?
    var date: Date
    var source: String
    var changeTag: String?
    var encodedSystemFields: Data?
    var sourceZoneName: String?
    var sourceZoneOwnerName: String?
    var sourceDatabaseScope: String?

    init(recordName: String,
         profileRecordName: String,
         familyRecordName: String,
         amount: Double,
         entryDescription: String,
         location: String? = nil,
         date: Date,
         source: String,
         changeTag: String? = nil,
         encodedSystemFields: Data? = nil,
         sourceZoneName: String? = nil,
         sourceZoneOwnerName: String? = nil,
         sourceDatabaseScope: String? = nil)
    {
        self.recordName = recordName
        self.profileRecordName = profileRecordName
        self.familyRecordName = familyRecordName
        self.amount = amount
        self.entryDescription = entryDescription
        self.location = location
        self.date = date
        self.source = source
        self.changeTag = changeTag
        self.encodedSystemFields = encodedSystemFields
        self.sourceZoneName = sourceZoneName
        self.sourceZoneOwnerName = sourceZoneOwnerName
        self.sourceDatabaseScope = sourceDatabaseScope
    }

    convenience init(from entry: LedgerEntry) {
        self.init(
            recordName: entry.id.recordName,
            profileRecordName: entry.profile.recordID.recordName,
            familyRecordName: entry.family.recordID.recordName,
            amount: entry.amount,
            entryDescription: entry.description,
            location: entry.location,
            date: entry.date,
            source: entry.source,
            changeTag: entry.changeTag,
            encodedSystemFields: entry.encodedSystemFields,
            sourceZoneName: entry.id.zoneID.zoneName,
            sourceZoneOwnerName: entry.id.zoneID.ownerName,
            sourceDatabaseScope: inferDatabaseScope(from: entry.id.zoneID)
        )
    }

    // MARK: - CacheMergeable

    func update(from entry: LedgerEntry, isServerSync: Bool = false) {
        profileRecordName = entry.profile.recordID.recordName
        familyRecordName = entry.family.recordID.recordName
        amount = entry.amount
        entryDescription = entry.description
        location = entry.location
        date = entry.date
        source = entry.source
        changeTag = entry.changeTag
        sourceZoneName = entry.id.zoneID.zoneName
        sourceZoneOwnerName = entry.id.zoneID.ownerName
        sourceDatabaseScope = inferDatabaseScope(from: entry.id.zoneID)
        if isServerSync, entry.encodedSystemFields != nil {
            encodedSystemFields = entry.encodedSystemFields
        }
    }

    static func fetchDescriptor(familyRecordName: String?) -> FetchDescriptor<LedgerEntryCache> {
        if let familyRecordName {
            return FetchDescriptor<LedgerEntryCache>(predicate: #Predicate { $0.familyRecordName == familyRecordName })
        }
        return FetchDescriptor<LedgerEntryCache>()
    }

    static func fetchDescriptor(recordName: String) -> FetchDescriptor<LedgerEntryCache> {
        FetchDescriptor<LedgerEntryCache>(predicate: #Predicate { $0.recordName == recordName })
    }
}
