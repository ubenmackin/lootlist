//
//  AllowancePeriodCache.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import SwiftData

@Model
final class AllowancePeriodCache: FamilyScopedCache, CacheMergeable {
    typealias DomainModel = AllowancePeriod

    #Index<AllowancePeriodCache>([\.familyRecordName, \.recordName], [\.familyRecordName, \.profileRecordName, \.weekOf])

    var recordName: String
    var profileRecordName: String
    var familyRecordName: String
    var weekOf: Date
    var status: String
    var totalEarned: Double
    var questsCompleted: Int
    var questsTotal: Int
    var paidDate: Date?
    var paidAmount: Double?
    var changeTag: String?
    var encodedSystemFields: Data?
    var sourceZoneName: String?
    var sourceZoneOwnerName: String?
    var sourceDatabaseScope: String?

    var statusEnum: PayoutStatus? {
        PayoutStatus(rawValue: status)
    }

    init(recordName: String,
         profileRecordName: String,
         familyRecordName: String,
         weekOf: Date,
         status: String,
         totalEarned: Double,
         questsCompleted: Int,
         questsTotal: Int,
         paidDate: Date? = nil,
         paidAmount: Double? = nil,
         changeTag: String? = nil,
         encodedSystemFields: Data? = nil,
         sourceZoneName: String? = nil,
         sourceZoneOwnerName: String? = nil,
         sourceDatabaseScope: String? = nil)
    {
        self.recordName = recordName
        self.profileRecordName = profileRecordName
        self.familyRecordName = familyRecordName
        self.weekOf = weekOf
        self.status = status
        self.totalEarned = totalEarned
        self.questsCompleted = questsCompleted
        self.questsTotal = questsTotal
        self.paidDate = paidDate
        self.paidAmount = paidAmount
        self.changeTag = changeTag
        self.encodedSystemFields = encodedSystemFields
        self.sourceZoneName = sourceZoneName
        self.sourceZoneOwnerName = sourceZoneOwnerName
        self.sourceDatabaseScope = sourceDatabaseScope
    }

    convenience init(from period: AllowancePeriod) {
        self.init(
            recordName: period.id.recordName,
            profileRecordName: period.profile.recordID.recordName,
            familyRecordName: period.family.recordID.recordName,
            weekOf: period.weekOf,
            status: period.status.rawValue,
            totalEarned: period.totalEarned,
            questsCompleted: period.questsCompleted,
            questsTotal: period.questsTotal,
            paidDate: period.paidDate,
            paidAmount: period.paidAmount,
            changeTag: period.changeTag,
            encodedSystemFields: period.encodedSystemFields,
            sourceZoneName: period.id.zoneID.zoneName,
            sourceZoneOwnerName: period.id.zoneID.ownerName,
            sourceDatabaseScope: inferDatabaseScope(from: period.id.zoneID)
        )
    }

    // MARK: - CacheMergeable

    func update(from period: AllowancePeriod, isServerSync: Bool = false) {
        profileRecordName = period.profile.recordID.recordName
        familyRecordName = period.family.recordID.recordName
        weekOf = period.weekOf
        status = period.status.rawValue
        totalEarned = period.totalEarned
        questsCompleted = period.questsCompleted
        questsTotal = period.questsTotal
        paidDate = period.paidDate
        paidAmount = period.paidAmount
        changeTag = period.changeTag
        sourceZoneName = period.id.zoneID.zoneName
        sourceZoneOwnerName = period.id.zoneID.ownerName
        sourceDatabaseScope = inferDatabaseScope(from: period.id.zoneID)
        if isServerSync, period.encodedSystemFields != nil {
            encodedSystemFields = period.encodedSystemFields
        }
    }

    static func fetchDescriptor(familyRecordName: String?) -> FetchDescriptor<AllowancePeriodCache> {
        if let familyRecordName {
            return FetchDescriptor<AllowancePeriodCache>(predicate: #Predicate { $0.familyRecordName == familyRecordName })
        }
        return FetchDescriptor<AllowancePeriodCache>()
    }

    static func fetchDescriptor(recordName: String) -> FetchDescriptor<AllowancePeriodCache> {
        FetchDescriptor<AllowancePeriodCache>(predicate: #Predicate { $0.recordName == recordName })
    }
}
