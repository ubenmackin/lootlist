//
//  CacheMergeable+Grouping.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation

/// Groups domain models by their embedded familyRecordName for nil-scope batches.
func groupedByFamily<T: CacheMergeable>(_: T.Type, items: [T.DomainModel]) -> [String: [T.DomainModel]] {
    Dictionary(grouping: items) { T(from: $0).familyRecordName }
}
