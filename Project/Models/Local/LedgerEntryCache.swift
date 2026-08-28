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
    /// Free-form movement tag; allowed values mirror `LedgerEntry.source`
    /// ("manual", "quest", "interest", "match", "transfer", import-tagged).
    var source: String
    // Bucket attribution (V8) — raw `BucketKind` strings; nil for legacy rows.
    var bucketKind: String?
    var fromBucket: String?
    var toBucket: String?
    var changeTag: String?
    var encodedSystemFields: Data?
    var sourceZoneName: String?
    var sourceZoneOwnerName: String?
    var sourceDatabaseScope: String?

    var bucketKindEnum: BucketKind? {
        bucketKind.flatMap { BucketKind(rawValue: $0) }
    }

    /// Typed view of `source` for exhaustive switching. Additive migration —
    /// `source` remains the persisted CloudKit string.
    var sourceEnum: LedgerSource? {
        if source.hasPrefix(LedgerSource.import.rawValue) {
            return .import
        }
        return LedgerSource(rawValue: source)
    }

    init(recordName: String,
         profileRecordName: String,
         familyRecordName: String,
         amount: Double,
         entryDescription: String,
         location: String? = nil,
         date: Date,
         source: String,
         bucketKind: String? = nil,
         fromBucket: String? = nil,
         toBucket: String? = nil,
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
        self.bucketKind = bucketKind
        self.fromBucket = fromBucket
        self.toBucket = toBucket
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
            bucketKind: entry.bucketKind,
            fromBucket: entry.fromBucket,
            toBucket: entry.toBucket,
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
        bucketKind = entry.bucketKind
        fromBucket = entry.fromBucket
        toBucket = entry.toBucket
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
