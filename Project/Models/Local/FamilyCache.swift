//
//  FamilyCache.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import SwiftData

/// Root partition record — never family-scoped. WHY: family IS the partition, so familyRecordName would be circular; WHY no migration: composite index would force
/// backfill/destructive reset for zero isolation gain.
@Model
final class FamilyCache: CacheMergeable {
    typealias DomainModel = Family

    // WHY single-column index: root has no familyRecordName to composite with.
    #Index<FamilyCache>([\.recordName])

    var recordName: String
    var name: String
    var createdByRecordName: String
    var createdAt: Date
    var payoutPolicy: String
    /// Declaration-level default mirrors the init default so the V2 → V3
    /// lightweight migration can backfill legacy rows with the app fallback.
    var payoutDay: String = PayoutDay.sunday.rawValue
    var changeTag: String?
    /// iCloud user record name of the family's founding user, mirrored from
    /// `Family.creatorUserRecordName` (server-stamped `creatorUserRecordID`).
    /// Optional so legacy rows predating the anchor migrate in cleanly with nil.
    var creatorUserRecordName: String?
    var encodedSystemFields: Data?
    var sourceZoneName: String?
    var sourceZoneOwnerName: String?
    var sourceDatabaseScope: String?

    /// `FamilyCache` is the root record and is never family-scoped — WHY circular: recordName IS the partition key.
    var familyRecordName: String {
        ""
    }

    var payoutPolicyEnum: PayoutPolicy? {
        PayoutPolicy(rawValue: payoutPolicy)
    }

    var payoutDayEnum: PayoutDay? {
        PayoutDay(rawValue: payoutDay)
    }

    init(recordName: String,
         name: String,
         createdByRecordName: String,
         createdAt: Date,
         payoutPolicy: String,
         payoutDay: String = PayoutDay.sunday.rawValue,
         changeTag: String? = nil,
         creatorUserRecordName: String? = nil,
         encodedSystemFields: Data? = nil,
         sourceZoneName: String? = nil,
         sourceZoneOwnerName: String? = nil,
         sourceDatabaseScope: String? = nil)
    {
        self.recordName = recordName
        self.name = name
        self.createdByRecordName = createdByRecordName
        self.createdAt = createdAt
        self.payoutPolicy = payoutPolicy
        self.payoutDay = payoutDay
        self.changeTag = changeTag
        self.creatorUserRecordName = creatorUserRecordName
        self.encodedSystemFields = encodedSystemFields
        self.sourceZoneName = sourceZoneName
        self.sourceZoneOwnerName = sourceZoneOwnerName
        self.sourceDatabaseScope = sourceDatabaseScope
    }

    convenience init(from family: Family) {
        self.init(
            recordName: family.id.recordName,
            name: family.name,
            createdByRecordName: family.createdBy.recordName,
            createdAt: family.createdAt,
            payoutPolicy: family.payoutPolicy.rawValue,
            payoutDay: family.payoutDay.rawValue,
            changeTag: family.changeTag,
            creatorUserRecordName: family.creatorUserRecordName,
            encodedSystemFields: family.encodedSystemFields,
            sourceZoneName: family.id.zoneID.zoneName,
            sourceZoneOwnerName: family.id.zoneID.ownerName,
            sourceDatabaseScope: inferDatabaseScope(from: family.id.zoneID)
        )
    }

    // MARK: - CacheMergeable

    func update(from family: Family, isServerSync: Bool = false) {
        name = family.name
        createdByRecordName = family.createdBy.recordName
        createdAt = family.createdAt
        payoutPolicy = family.payoutPolicy.rawValue
        payoutDay = family.payoutDay.rawValue
        changeTag = family.changeTag
        creatorUserRecordName = family.creatorUserRecordName
        sourceZoneName = family.id.zoneID.zoneName
        sourceZoneOwnerName = family.id.zoneID.ownerName
        sourceDatabaseScope = inferDatabaseScope(from: family.id.zoneID)
        if isServerSync, family.encodedSystemFields != nil {
            encodedSystemFields = family.encodedSystemFields
        }
    }

    static func fetchDescriptor(familyRecordName _: String?) -> FetchDescriptor<FamilyCache> {
        // WHY ignored: FamilyCache is the root record — never family-scoped, so predicate is unscoped.
        FetchDescriptor<FamilyCache>()
    }

    static func fetchDescriptor(recordName: String) -> FetchDescriptor<FamilyCache> {
        FetchDescriptor<FamilyCache>(predicate: #Predicate { $0.recordName == recordName })
    }
}
