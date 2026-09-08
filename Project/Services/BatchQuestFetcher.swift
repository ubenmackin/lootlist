//
//  BatchQuestFetcher.swift
//  LootList
//
//  Created by Ben Mackin on 8/20/26.
//

import CloudKit
import Foundation
import os

enum BatchQuestFetcher {
    private static let logger = Logger(category: "BatchQuestFetcher")

    @MainActor
    static func fetchMissingQuests<T: CloudKitRecord>(
        names: [String],
        family: Family,
        cloudKit: any CloudKitServiceProtocol
    ) async throws -> [T] where T.ID == CKRecord.ID {
        guard !names.isEmpty else { return [] }
        // WHY direct fetch by ID: recordName is not server-queryable, so the predicate path always misses on device and degrades to N sequential fetches.
        let uniqueNames = Array(Set(names))
        let zoneID = family.id.zoneID
        return try await withThrowingTaskGroup(of: T.self, returning: [T].self) { group in
            for recordName in uniqueNames {
                group.addTask {
                    let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
                    do {
                        return try await cloudKit.fetch(T.self, id: recordID)
                    } catch {
                        logger.warning("Failed to fetch \(T.recordType, privacy: .public) \(recordName, privacy: .private): \(error, privacy: .private)")
                        throw error
                    }
                }
            }
            var collected: [T] = []
            collected.reserveCapacity(uniqueNames.count)
            for try await item in group {
                collected.append(item)
            }
            return collected
        }
    }
}
