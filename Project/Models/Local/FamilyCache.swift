//
//  FamilyCache.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation
import SwiftData

@Model
final class FamilyCache: CacheMergeable {
    typealias DomainModel = Family

    // The `#Index<FamilyCache>([\.recordName])` macro was removed: it
    // duplicated the implicit unique index already provided by
    // `@Attribute(.unique) var recordName` below. Query predicates on
    // `recordName` continue to use the unique attribute's implicit index.

    @Attribute(.unique) var recordName: String
    var name: String
    var createdByRecordName: String
    var createdAt: Date
    var payoutPolicy: String
    /// Declaration-level default mirrors the init default so the V2 → V3
    /// lightweight migration can backfill legacy rows with the app fallback.
    var payoutDay: String = PayoutDay.sunday.rawValue
    var changeTag: String?

    /// `FamilyCache` is the root record and is never family-scoped.
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
         changeTag: String? = nil)
    {
        self.recordName = recordName
        self.name = name
        self.createdByRecordName = createdByRecordName
        self.createdAt = createdAt
        self.payoutPolicy = payoutPolicy
        self.payoutDay = payoutDay
        self.changeTag = changeTag
    }

    convenience init(from family: Family) {
        self.init(
            recordName: family.id.recordName,
            name: family.name,
            createdByRecordName: family.createdBy.recordName,
            createdAt: family.createdAt,
            payoutPolicy: family.payoutPolicy.rawValue,
            payoutDay: family.payoutDay.rawValue,
            changeTag: family.changeTag
        )
    }

    // MARK: - CacheMergeable

    func update(from family: Family) {
        name = family.name
        createdByRecordName = family.createdBy.recordName
        createdAt = family.createdAt
        payoutPolicy = family.payoutPolicy.rawValue
        payoutDay = family.payoutDay.rawValue
        changeTag = family.changeTag
    }

    static func fetchDescriptor(familyRecordName _: String?) -> FetchDescriptor<FamilyCache> {
        // FamilyCache is the root record — never family-scoped.
        FetchDescriptor<FamilyCache>()
    }

    static func fetchDescriptor(recordName: String) -> FetchDescriptor<FamilyCache> {
        FetchDescriptor<FamilyCache>(predicate: #Predicate { $0.recordName == recordName })
    }
}
