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
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "BatchQuestFetcher")

    @MainActor
    static func fetchMissingQuests<T: CloudKitRecord>(
        names: [String],
        family: Family,
        cloudKit: any CloudKitServiceProtocol
    ) async throws -> [T] where T.ID == CKRecord.ID {
        var map: [String: T] = [:]
        guard !names.isEmpty else { return [] }
        let chunkSize = 100
        for start in stride(from: 0, to: names.count, by: chunkSize) {
            let end = min(start + chunkSize, names.count)
            let chunk = Array(names[start ..< end])
            let predicate = NSPredicate(format: "recordName IN %@", chunk)
            do {
                let fetched: [T] = try await cloudKit.query(
                    T.self,
                    predicate: predicate,
                    in: family.id.zoneID
                )
                for item in fetched {
                    map[item.id.recordName] = item
                }
            } catch {
                logger.warning("Batch fetch failed for quest chunk: \(error, privacy: .private)")
                throw error
            }
        }
        let stillMissing = names.filter { map[$0] == nil }
        if !stillMissing.isEmpty {
            for recordName in stillMissing {
                let recordID = CKRecord.ID(recordName: recordName, zoneID: family.id.zoneID)
                do {
                    let fetched: T = try await cloudKit.fetch(T.self, id: recordID)
                    map[fetched.id.recordName] = fetched
                } catch {
                    logger.warning("Failed to fetch quest \(recordName, privacy: .private): \(error, privacy: .private)")
                    throw error
                }
            }
        }
        return Array(map.values)
    }
}
