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

    // WHY: lean transfer guard index — (family, profile, source, date) narrows hasTransferredToday without sparse optional columns; pair filter refines the small indexed subset.
    // WARNING: Do not add fromBucket/toBucket to DB predicate — sparse optionals not indexed, would force table scan. Filter in-memory.
    #Index<LedgerEntryCache>(
        [\.familyRecordName, \.recordName],
        [\.familyRecordName, \.profileRecordName, \.date],
        [\.familyRecordName, \.profileRecordName, \.source, \.date]
    )

    var recordName: String
    var profileRecordName: String
    var familyRecordName: String
    /// Whole pennies (signed) — mirrors `LedgerEntry.amount`.
    var amount: Int64
    var entryDescription: String
    var location: String?
    var date: Date
    /// Free-form movement tag. Typed view available via `sourceEnum`
    /// (`LedgerSource`: manual/quest/interest/match/transfer/goal/purchase/
    /// deposit/withdrawal, plus import-tagged entries).
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

    var formattedAmount: String {
        CurrencyFormatter.string(pennies: amount)
    }

    init(recordName: String,
         profileRecordName: String,
         familyRecordName: String,
         amount: Int64,
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
            toBucket: entry.toBucket
        )
        applySystemFields(from: entry)
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
        applySystemFields(from: entry, isServerSync: isServerSync)
    }

    static func fetchDescriptor(familyRecordName: String?) -> FetchDescriptor<LedgerEntryCache> {
        if let familyRecordName, !familyRecordName.isEmpty {
            return FetchDescriptor<LedgerEntryCache>(predicate: #Predicate { $0.familyRecordName == familyRecordName })
        }
        // WHY fail-closed: nil/empty scope must match zero rows, never the whole table.
        return FetchDescriptor<LedgerEntryCache>(predicate: #Predicate { $0.familyRecordName == "" })
    }

    static func fetchDescriptor(recordName: String, familyRecordName: String) -> FetchDescriptor<LedgerEntryCache> {
        FetchDescriptor<LedgerEntryCache>(predicate: #Predicate { $0.recordName == recordName && $0.familyRecordName == familyRecordName })
    }

    // MARK: - Family Predicates

    /// WHY single source: views share the family isolation boundary so store filtering never drifts.
    static func familyPredicate(familyRecordName: String) -> Predicate<LedgerEntryCache> {
        let targetFamily = familyRecordName
        return #Predicate<LedgerEntryCache> { $0.familyRecordName == targetFamily }
    }

    /// WHY single source: hero-scoped reads push family+profile to the store instead of scanning.
    static func profilePredicate(familyRecordName: String, profileRecordName: String) -> Predicate<LedgerEntryCache> {
        let targetFamily = familyRecordName
        let targetProfile = profileRecordName
        return #Predicate<LedgerEntryCache> {
            $0.familyRecordName == targetFamily && $0.profileRecordName == targetProfile
        }
    }

    /// WHY single source: import counts share the deterministic prefix definition.
    static func importPredicate(familyRecordName: String) -> Predicate<LedgerEntryCache> {
        let targetFamily = familyRecordName
        return #Predicate<LedgerEntryCache> {
            $0.familyRecordName == targetFamily && $0.recordName.starts(with: "import-")
        }
    }
}
