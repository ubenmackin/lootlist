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
protocol FamilyScopedCache: PersistentModel {
    var recordName: String { get }
    var familyRecordName: String { get }
}
