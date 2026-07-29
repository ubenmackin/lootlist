//
//  AllowancePeriodCache.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation
import SwiftData

@Model
final class AllowancePeriodCache: FamilyScopedCache {
    #Index<AllowancePeriodCache>([\.familyRecordName], [\.profileRecordName], [\.weekOf])

    @Attribute(.unique) var recordName: String
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
         changeTag: String? = nil)
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
            changeTag: period.changeTag
        )
    }
}
