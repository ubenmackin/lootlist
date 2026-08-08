//
//  FamilyScopedCache.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import SwiftData

/// Conformed by every `@Model` cache whose rows are partitioned by family.
/// `FamilyCache` itself does NOT conform — it is the root record and is queried
/// only by its own `recordName`.
///
/// NOTE: Enum convenience getters in `*Cache` models follow a standardized pattern:
/// they always use an `*Enum` suffix and always return an optional value (e.g.
/// `var approvalModeEnum: ApprovalMode? { ApprovalMode(rawValue: approvalMode) }`).
protocol FamilyScopedCache: PersistentModel {
    var recordName: String { get }
    var familyRecordName: String { get }
}

/// CloudKit domain models that can be merged into cache rows. Conforming types
/// expose the record name used to key the cache by `recordName`.
protocol CacheMergeableDomain {
    var id: CKRecord.ID { get }
}

/// Protocol for cache models that support merging updates from CloudKit domain
/// models. The field-for-field merge logic lives in `update(from:)` so the
/// generic batch helpers in `BackgroundCacheActor` stay free of per-type
/// scaffolding while keeping every SwiftData property assignment explicit and
/// type-safe (no reflection, no dynamic key paths).
///
/// `#Predicate` cannot be written generically (it is a compile-time macro
/// needing a concrete type), so each conformance provides its own
/// `fetchDescriptor(familyRecordName:)` for the family-scoped fetch and its own
/// `fetchDescriptor(recordName:)` for the unique recordName lookup.
protocol CacheMergeable: PersistentModel {
    associatedtype DomainModel: CacheMergeableDomain

    var recordName: String { get }

    /// The family this row is scoped to. `FamilyCache` is the root record and
    /// returns an empty string — it is never family-scoped.
    var familyRecordName: String { get }

    /// Creates a new cache row from the domain model.
    init(from domain: DomainModel)

    /// Applies a field-for-field update from the domain model onto an existing
    /// row. `changeTag` is copied unconditionally — nil is a meaningful
    /// "no further tag" value that must propagate.
    func update(from domain: DomainModel)

    /// Returns the fetch descriptor used by the generic batch helpers.
    /// `FamilyCache` ignores `familyRecordName` (root record, never scoped).
    static func fetchDescriptor(familyRecordName: String?) -> FetchDescriptor<Self>

    /// Returns a fetch descriptor scoped to the unique `recordName` key. Used by
    /// the generic single-record delete helper in `BackgroundCacheActor` so the
    /// lookup stays on the unique attribute's implicit index instead of pulling
    /// the full table and filtering in memory.
    static func fetchDescriptor(recordName: String) -> FetchDescriptor<Self>
}

extension CacheMergeable {
    /// Hoisted single & batch upsert field-application helper shared across CacheService upserts.
    static func apply(_ cached: Self, from domain: DomainModel) {
        cached.update(from: domain)
    }
}
