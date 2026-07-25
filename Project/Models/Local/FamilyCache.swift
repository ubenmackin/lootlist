//
//  FamilyCache.swift
//  LootList
//
//  Created for Local-First SwiftData Architecture.
//

import Foundation
import SwiftData

@Model
final class FamilyCache {
    @Attribute(.unique) var recordName: String
    var name: String
    var createdByRecordName: String
    var createdAt: Date
    var payoutPolicy: String

    init(recordName: String,
         name: String,
         createdByRecordName: String,
         createdAt: Date,
         payoutPolicy: String)
    {
        self.recordName = recordName
        self.name = name
        self.createdByRecordName = createdByRecordName
        self.createdAt = createdAt
        self.payoutPolicy = payoutPolicy
    }

    convenience init(from family: Family) {
        self.init(
            recordName: family.id.recordName,
            name: family.name,
            createdByRecordName: family.createdBy.recordName,
            createdAt: family.createdAt,
            payoutPolicy: family.payoutPolicy.rawValue
        )
    }
}
