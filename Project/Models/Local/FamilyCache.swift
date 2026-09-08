//
//  FamilyCache.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import SwiftData

/// Root partition record — not family-scoped since the family is the partition boundary.
@Model
final class FamilyCache: CacheMergeable {
    typealias DomainModel = Family

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

    /// `FamilyCache` is the root record and is not scoped to another family.
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
        // WHY legacy display only: empty never authorizes, the anchor passes through as-is.
        self.init(
            recordName: family.id.recordName,
            name: family.name,
            createdByRecordName: family.creatorUserRecordName ?? "",
            createdAt: family.createdAt,
            payoutPolicy: family.payoutPolicy.rawValue,
            payoutDay: family.payoutDay.rawValue,
            creatorUserRecordName: family.creatorUserRecordName
        )
        applySystemFields(from: family)
    }

    // MARK: - CacheMergeable

    func update(from family: Family, isServerSync: Bool = false) {
        name = family.name
        // WHY legacy display only: empty never authorizes, the anchor passes through as-is.
        createdByRecordName = family.creatorUserRecordName ?? ""
        createdAt = family.createdAt
        payoutPolicy = family.payoutPolicy.rawValue
        payoutDay = family.payoutDay.rawValue
        creatorUserRecordName = family.creatorUserRecordName
        applySystemFields(from: family, isServerSync: isServerSync)
    }

    static func fetchDescriptor(familyRecordName _: String?) -> FetchDescriptor<FamilyCache> {
        FetchDescriptor<FamilyCache>()
    }

    static func fetchDescriptor(recordName: String) -> FetchDescriptor<FamilyCache> {
        FetchDescriptor<FamilyCache>(predicate: #Predicate { $0.recordName == recordName })
    }

    static func fetchDescriptor(recordName: String, familyRecordName _: String) -> FetchDescriptor<FamilyCache> {
        FetchDescriptor<FamilyCache>(predicate: #Predicate { $0.recordName == recordName })
    }

    // MARK: - Family Predicates

    /// WHY single source: diagnostics share the root lookup so the family slice never drifts.
    static func recordPredicate(recordName: String) -> Predicate<FamilyCache> {
        let targetFamily = recordName
        return #Predicate<FamilyCache> { $0.recordName == targetFamily }
    }
}
