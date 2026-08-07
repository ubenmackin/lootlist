//
//  CloudKitService+Query.swift
//  LootList
//
//  Created by Ben Mackin on August 6, 2026.
//

import CloudKit
import Foundation

extension CloudKitService {
    func query<T: CloudKitRecord>(_ type: T.Type,
                                  predicate: NSPredicate,
                                  in zoneID: CKRecordZone.ID? = nil,
                                  sortDescriptors: [NSSortDescriptor]? = nil,
                                  using db: CKDatabase? = nil) async throws -> [T]
    {
        if isTestingOrMocking {
            let matching = mockRecords.values.filter { record in
                guard record.recordType == T.recordType else { return false }
                return evaluateMockPredicate(predicate, record: record)
            }
            let sorted = sortMockRecords(Array(matching), sortDescriptors: sortDescriptors)
            return try sorted.map { try T(record: $0) }
        }

        let zone = zoneID ?? resolvedZoneID
        let targetDB = db ?? activeFamilyDatabase
        let query = CKQuery(recordType: type.recordType, predicate: predicate)
        query.sortDescriptors = sortDescriptors

        var allMatchResults: [(CKRecord.ID, Result<CKRecord, Error>)] = []
        let maximumResults = CKQueryOperation.maximumResults

        let (firstPageResults, firstCursor) = try await retrying {
            try await targetDB.records(matching: query,
                                       inZoneWith: zone,
                                       resultsLimit: maximumResults)
        }
        allMatchResults.append(contentsOf: firstPageResults)
        var cursor: CKQueryOperation.Cursor? = firstCursor

        var pageCount = 1
        while let nextCursor = cursor {
            guard pageCount < Self.maxFetchPages else {
                throw CloudKitServiceError.paginationExhausted(pageBudget: Self.maxFetchPages)
            }
            let (pageResults, nextPageCursor) = try await retrying {
                try await targetDB.records(continuingMatchFrom: nextCursor,
                                           resultsLimit: maximumResults)
            }
            allMatchResults.append(contentsOf: pageResults)
            cursor = nextPageCursor
            pageCount += 1
        }

        var records: [CKRecord] = []
        for match in allMatchResults {
            switch match.1 {
            case let .success(record):
                records.append(record)
            case let .failure(error):
                throw wrapError(error)
            }
        }
        return try records.map { try T(record: $0) }
    }
}
