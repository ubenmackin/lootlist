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
        guard let zone = zoneID ?? activeFamilyZoneID else {
            logger.error("CloudKitService.query rejected: no explicit zoneID or activeFamilyZoneID available")
            throw CloudKitServiceError.invalidArguments("CloudKitService.query requires an explicit zoneID or activeFamilyZoneID")
        }

        guard let targetDB = db ?? activeFamilyDatabase else {
            logger.error("CloudKitService.query rejected: no target database provided and no activeFamilyDatabase available")
            throw CloudKitServiceError.accountUnavailable
        }
        let query = CKQuery(recordType: type.recordType, predicate: predicate)
        query.sortDescriptors = sortDescriptors

        var allMatchResults: [(CKRecord.ID, Result<CKRecord, Error>)] = []
        let maximumResults = CKQueryOperation.maximumResults

        let (firstPageResults, firstCursor): ([(CKRecord.ID, Result<CKRecord, Error>)], CKQueryOperation.Cursor?)
        do {
            (firstPageResults, firstCursor) = try await retrying {
                try await targetDB.records(matching: query,
                                           inZoneWith: zone,
                                           resultsLimit: maximumResults)
            }
        } catch {
            let wrapped = wrapError(error)
            switch wrapped {
            case .notFound:
                // Record type or zone does not exist yet on CloudKit server — return empty results.
                return []
            case let .invalidArguments(msg) where msg.contains("not marked queryable") || msg.contains("not marked indexable") || msg.contains("recordName"):
                // Record type lacks a queryable index on CloudKit server — return empty results.
                return []
            default:
                throw wrapped
            }
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
