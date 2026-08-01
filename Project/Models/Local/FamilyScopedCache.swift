//
//  FamilyScopedCache.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

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

/// Protocol for cache models that support merging updates from CloudKit domain models.
protocol CacheMergeable: PersistentModel {
    var recordName: String { get }
}
