//
//  FamilyScopedCache.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import SwiftData

/// Partition key protocol for SwiftData cache rows scoped by family.
protocol FamilyScopedCache: PersistentModel {
    var recordName: String { get }
    var familyRecordName: String { get }
    var sourceZoneName: String? { get }
    var sourceZoneOwnerName: String? { get }
    var sourceDatabaseScope: String? { get }
}

/// CloudKit domain models that can be merged into cache rows. Conforming types
/// expose the record name used to key the cache by `recordName`.
protocol CacheMergeableDomain {
    var id: CKRecord.ID { get }
}

/// Defines explicit typed field-for-field merge logic from CloudKit domain models.
protocol CacheMergeable: PersistentModel {
    associatedtype DomainModel: CacheMergeableDomain

    var recordName: String { get }

    /// The family this row is scoped to. `FamilyCache` is the root record and
    /// returns an empty string — it is never family-scoped.
    var familyRecordName: String { get }

    var sourceZoneName: String? { get }
    var sourceZoneOwnerName: String? { get }
    var sourceDatabaseScope: String? { get }

    /// Creates a new cache row from the domain model.
    init(from domain: DomainModel)

    /// Applies field updates from domain model; changeTag is copied unconditionally.
    func update(from domain: DomainModel, isServerSync: Bool)

    /// Returns the fetch descriptor used by the generic batch helpers.
    /// `FamilyCache` ignores `familyRecordName` (root record, never scoped).
    static func fetchDescriptor(familyRecordName: String?) -> FetchDescriptor<Self>

    /// Returns a fetch descriptor scoped to the unique recordName key.
    static func fetchDescriptor(recordName: String) -> FetchDescriptor<Self>

    /// Returns a fetch descriptor scoped to both recordName and familyRecordName composite index.
    static func fetchDescriptor(recordName: String, familyRecordName: String) -> FetchDescriptor<Self>
}

extension CacheMergeable {
    func update(from domain: DomainModel) {
        update(from: domain, isServerSync: false)
    }

    /// Hoisted single & batch upsert field-application helper shared across CacheService upserts.
    static func apply(_ cached: Self, from domain: DomainModel, isServerSync: Bool = false) {
        cached.update(from: domain, isServerSync: isServerSync)
    }
}
