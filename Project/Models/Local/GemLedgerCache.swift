//
//  GemLedgerCache.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import CloudKit
import Foundation
import SwiftData

@Model
final class GemLedgerCache: FamilyScopedCache, CacheMergeable {
    typealias DomainModel = GemLedger

    #Index<GemLedgerCache>([\.familyRecordName, \.recordName], [\.familyRecordName, \.profileRecordName])

    var recordName: String
    var profileRecordName: String
    var familyRecordName: String
    var amount: Int
    var source: String
    var sourceDetail: String?
    var createdAt: Date
    var changeTag: String?
    var encodedSystemFields: Data?
    var sourceZoneName: String?
    var sourceZoneOwnerName: String?
    var sourceDatabaseScope: String?

    var isDebit: Bool {
        amount < 0
    }

    init(recordName: String,
         profileRecordName: String,
         familyRecordName: String,
         amount: Int,
         source: String,
         sourceDetail: String? = nil,
         createdAt: Date,
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
        self.source = source
        self.sourceDetail = sourceDetail
        self.createdAt = createdAt
        self.changeTag = changeTag
        self.encodedSystemFields = encodedSystemFields
        self.sourceZoneName = sourceZoneName
        self.sourceZoneOwnerName = sourceZoneOwnerName
        self.sourceDatabaseScope = sourceDatabaseScope
    }

    convenience init(from entry: GemLedger) {
        self.init(
            recordName: entry.id.recordName,
            profileRecordName: entry.profileRecordName,
            familyRecordName: entry.family.recordID.recordName,
            amount: entry.amount,
            source: entry.source,
            sourceDetail: entry.sourceDetail,
            createdAt: entry.createdAt,
            changeTag: entry.changeTag,
            encodedSystemFields: entry.encodedSystemFields,
            sourceZoneName: entry.id.zoneID.zoneName,
            sourceZoneOwnerName: entry.id.zoneID.ownerName,
            sourceDatabaseScope: inferDatabaseScope(from: entry.id.zoneID)
        )
    }

    // MARK: - CacheMergeable

    func update(from entry: GemLedger, isServerSync: Bool = false) {
        profileRecordName = entry.profileRecordName
        familyRecordName = entry.family.recordID.recordName
        amount = entry.amount
        source = entry.source
        sourceDetail = entry.sourceDetail
        createdAt = entry.createdAt
        changeTag = entry.changeTag
        sourceZoneName = entry.id.zoneID.zoneName
        sourceZoneOwnerName = entry.id.zoneID.ownerName
        sourceDatabaseScope = inferDatabaseScope(from: entry.id.zoneID)
        if isServerSync, entry.encodedSystemFields != nil {
            encodedSystemFields = entry.encodedSystemFields
        }
    }

    static func fetchDescriptor(familyRecordName: String?) -> FetchDescriptor<GemLedgerCache> {
        if let familyRecordName {
            return FetchDescriptor<GemLedgerCache>(predicate: #Predicate { $0.familyRecordName == familyRecordName })
        }
        return FetchDescriptor<GemLedgerCache>()
    }

    static func fetchDescriptor(recordName: String) -> FetchDescriptor<GemLedgerCache> {
        FetchDescriptor<GemLedgerCache>(predicate: #Predicate { $0.recordName == recordName })
    }
}
