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
    /// Whole pennies — mirrors `AllowancePeriod.totalEarned`.
    var totalEarned: Int64
    var questsCompleted: Int
    var questsTotal: Int
    var paidDate: Date?
    /// Nil means unpaid; mirrors `AllowancePeriod.paidAmount`.
    var paidAmount: Int64?
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
         totalEarned: Int64,
         questsCompleted: Int,
         questsTotal: Int,
         paidDate: Date? = nil,
         paidAmount: Int64? = nil,
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
            paidAmount: period.paidAmount
        )
        applySystemFields(from: period)
    }

    // MARK: - CacheMergeable

    func update(from period: AllowancePeriod, isServerSync: Bool = false) {
        profileRecordName = period.profile.recordID.recordName
        familyRecordName = period.family.recordID.recordName
        weekOf = period.weekOf
        if isServerSync {
            let currentRank = PayoutStatus(rawValue: status)?.rank ?? 0
            if period.status.rank >= currentRank {
                status = period.status.rawValue
            }
            totalEarned = max(totalEarned, period.totalEarned)
            questsCompleted = max(questsCompleted, period.questsCompleted)
            questsTotal = max(questsTotal, period.questsTotal)
            paidAmount = {
                if paidAmount == nil, period.paidAmount == nil {
                    return nil
                }
                return max(paidAmount ?? 0, period.paidAmount ?? 0)
            }()
            paidDate = period.paidDate ?? paidDate
        } else {
            status = period.status.rawValue
            totalEarned = period.totalEarned
            questsCompleted = period.questsCompleted
            questsTotal = period.questsTotal
            paidDate = period.paidDate
            paidAmount = period.paidAmount
        }
        applySystemFields(from: period, isServerSync: isServerSync)
    }

    static func fetchDescriptor(familyRecordName: String?) -> FetchDescriptor<AllowancePeriodCache> {
        if let familyRecordName, !familyRecordName.isEmpty {
            return FetchDescriptor<AllowancePeriodCache>(predicate: #Predicate { $0.familyRecordName == familyRecordName })
        }
        // WHY fail-closed: nil/empty scope must match zero rows, never the whole table.
        return FetchDescriptor<AllowancePeriodCache>(predicate: #Predicate { $0.familyRecordName == "" })
    }

    static func fetchDescriptor(recordName: String, familyRecordName: String) -> FetchDescriptor<AllowancePeriodCache> {
        FetchDescriptor<AllowancePeriodCache>(predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == familyRecordName })
    }

    // MARK: - Family Predicates

    /// WHY single source: views share the family isolation boundary so store filtering never drifts.
    static func familyPredicate(familyRecordName: String) -> Predicate<AllowancePeriodCache> {
        let targetFamily = familyRecordName
        return #Predicate<AllowancePeriodCache> { $0.familyRecordName == targetFamily }
    }

    /// WHY single source: hero-scoped reads push family+profile to the store instead of scanning.
    static func profilePredicate(familyRecordName: String, profileRecordName: String) -> Predicate<AllowancePeriodCache> {
        let targetFamily = familyRecordName
        let targetProfile = profileRecordName
        return #Predicate<AllowancePeriodCache> {
            $0.familyRecordName == targetFamily && $0.profileRecordName == targetProfile
        }
    }
}
