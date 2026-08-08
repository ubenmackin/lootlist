//
//  CloudKitService+Fetch.swift
//  LootList
//
//  Created by Ben Mackin on August 6, 2026.
//

import CloudKit
import Foundation

extension CloudKitService {
    func fetch<T: CloudKitRecord>(_: T.Type,
                                  id: CKRecord.ID,
                                  using db: CKDatabase? = nil) async throws -> T
    {
        if isTestingOrMocking {
            if let record = mockRecords[id.recordName] {
                return try T(record: record)
            }
            throw CloudKitServiceError.notFound(id.recordName)
        }

        guard let targetDB = db ?? activeFamilyDatabase else {
            throw CloudKitServiceError.accountUnavailable
        }
        let record = try await retrying {
            try await targetDB.record(for: id)
        }
        return try T(record: record)
    }

    func currentUserRecordID() async throws -> CKRecord.ID {
        try await container.userRecordID()
    }

    func accountStatus() async throws -> CKAccountStatus {
        do {
            return try await container.accountStatus()
        } catch {
            throw wrapError(error)
        }
    }
}
