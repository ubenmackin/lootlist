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
            createdAt: entry.createdAt
        )
        applySystemFields(from: entry)
    }

    // MARK: - CacheMergeable

    func update(from entry: GemLedger, isServerSync: Bool = false) {
        profileRecordName = entry.profileRecordName
        familyRecordName = entry.family.recordID.recordName
        amount = entry.amount
        source = entry.source
        sourceDetail = entry.sourceDetail
        createdAt = entry.createdAt
        applySystemFields(from: entry, isServerSync: isServerSync)
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

    static func fetchDescriptor(recordName: String, familyRecordName: String) -> FetchDescriptor<GemLedgerCache> {
        FetchDescriptor<GemLedgerCache>(predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == familyRecordName })
    }

    // MARK: - Family Predicates

    /// WHY single source: views share the family isolation boundary so store filtering never drifts.
    static func familyPredicate(familyRecordName: String) -> Predicate<GemLedgerCache> {
        let targetFamily = familyRecordName
        return #Predicate<GemLedgerCache> { $0.familyRecordName == targetFamily }
    }

    /// WHY single source: hero-scoped reads push family+profile to the store instead of scanning.
    static func profilePredicate(familyRecordName: String, profileRecordName: String) -> Predicate<GemLedgerCache> {
        let targetFamily = familyRecordName
        let targetProfile = profileRecordName
        return #Predicate<GemLedgerCache> {
            $0.familyRecordName == targetFamily && $0.profileRecordName == targetProfile
        }
    }

    /// WHY fail-closed: empty scope returns zero rows via the index, never an unscoped scan.
    static func emptyPredicate() -> Predicate<GemLedgerCache> {
        #Predicate<GemLedgerCache> { $0.familyRecordName == "__empty__" }
    }
}
