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

    var sourceZoneName: String? { get set }
    var sourceZoneOwnerName: String? { get set }
    var sourceDatabaseScope: String? { get set }
    var changeTag: String? { get set }
    var encodedSystemFields: Data? { get set }

    /// Creates a new cache row from the domain model.
    init(from domain: DomainModel)

    /// Applies field updates from domain model; changeTag is copied unconditionally.
    func update(from domain: DomainModel, isServerSync: Bool)

    /// Copies zone, scope, changeTag and encoded fields from the domain model.
    /// Unconditional variant is for `init(from:)`; the flagged variant
    /// preserves local encoded snapshots on non-server writes.
    func applySystemFields(from domain: DomainModel)
    func applySystemFields(from domain: DomainModel, isServerSync: Bool)

    /// Returns the fetch descriptor used by the generic batch helpers.
    /// `FamilyCache` ignores `familyRecordName` (root record, never scoped).
    static func fetchDescriptor(familyRecordName: String?) -> FetchDescriptor<Self>

    /// Returns a fetch descriptor scoped to both recordName and familyRecordName composite index.
    static func fetchDescriptor(recordName: String, familyRecordName: String) -> FetchDescriptor<Self>
}

extension CacheMergeable {
    /// Hoisted single & batch upsert field-application helper shared across CacheService upserts.
    static func apply(_ cached: Self, from domain: DomainModel, isServerSync: Bool = false) {
        cached.update(from: domain, isServerSync: isServerSync)
    }
}

extension CacheMergeable where DomainModel: DomainSystemFields {
    func applySystemFields(from domain: DomainModel) {
        sourceZoneName = domain.id.zoneID.zoneName
        sourceZoneOwnerName = domain.id.zoneID.ownerName
        sourceDatabaseScope = inferDatabaseScope(from: domain.id.zoneID)
        changeTag = domain.changeTag
        encodedSystemFields = domain.encodedSystemFields
    }

    /// WHY conditional encoded: local writes must not clobber the server snapshot
    /// used for optimistic locking; server snapshots persist only when present.
    func applySystemFields(from domain: DomainModel, isServerSync: Bool) {
        sourceZoneName = domain.id.zoneID.zoneName
        sourceZoneOwnerName = domain.id.zoneID.ownerName
        sourceDatabaseScope = inferDatabaseScope(from: domain.id.zoneID)
        changeTag = domain.changeTag
        if isServerSync, domain.encodedSystemFields != nil {
            encodedSystemFields = domain.encodedSystemFields
        }
    }

    /// WHY explicit scope: server ingest holds the authoritative database scope, so stamping it after
    /// the field write outranks the zone-owner guess that decode-only callers must fall back on.
    /// Only the scope field is rewritten, leaving the encoded-system-field preservation rules intact.
    func applyExplicitDatabaseScope(_ scope: CKDatabase.Scope?, from domain: DomainModel) {
        guard let scope else { return }
        sourceDatabaseScope = inferDatabaseScope(from: domain.id.zoneID, explicitScope: scope)
    }
}
