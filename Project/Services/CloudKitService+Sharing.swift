//
//  CloudKitService+Sharing.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation

extension CloudKitService {
    func deleteZone(_ zoneID: CKRecordZone.ID) async throws {
        if isTestingOrMocking {
            return
        }
        let pvtDB = privateDatabase
        _ = try await retrying {
            try await pvtDB.deleteRecordZone(withID: zoneID)
        }
    }

    func ensureZoneExists(_ zoneID: CKRecordZone.ID) async throws {
        if isTestingOrMocking {
            return
        }
        let pvtDB = privateDatabase
        do {
            _ = try await retrying {
                try await pvtDB.recordZone(for: zoneID)
            }

        } catch let error as CloudKitServiceError {
            switch error {
            case .notFound:
                let zone = CKRecordZone(zoneID: zoneID)
                do {
                    _ = try await retrying { () -> CKRecordZone in
                        try await withCheckedThrowingContinuation { continuation in
                            pvtDB.save(zone) { zone, error in
                                if let error {
                                    continuation.resume(throwing: error)
                                } else {
                                    guard let zone else {
                                        continuation.resume(throwing: CKError(.internalError))
                                        return
                                    }
                                    continuation.resume(returning: zone)
                                }
                            }
                        }
                    }
                } catch {
                    throw CloudKitServiceError.zoneSetupFailed(
                        "Failed to create zone \(zoneID.zoneName): \(error)"
                    )
                }
            default:
                throw error
            }
        }
    }

    // MARK: - CKShare Support

    func createShare(for rootRecordID: CKRecord.ID) async throws -> CKShare {
        let pvtDB = privateDatabase
        let serverRoot = try await retrying {
            try await pvtDB.record(for: rootRecordID)
        }

        let share = CKShare(rootRecord: serverRoot)
        share[CKShare.SystemFieldKey.title] = (serverRoot["name"] as? String) ?? "Family Guild"
        // Required: public share link acts as bearer credential for family membership; participants must have readWrite access.
        share.publicPermission = .readWrite

        let operation = CKModifyRecordsOperation(
            recordsToSave: [serverRoot, share],
            recordIDsToDelete: nil
        )
        operation.isAtomic = true

        return try await withCheckedThrowingContinuation { continuation in
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: share)
                case let .failure(error):
                    continuation.resume(throwing: CloudKitServiceError.shareFailed(
                        "Failed to create share: \(error)"
                    ))
                }
            }
            pvtDB.add(operation)
        }
    }

    func fetchOrCreateShareURL(in zoneID: CKRecordZone.ID, rootRecordID: CKRecord.ID) async throws -> URL {
        if isTestingOrMocking {
            guard let url = URL(string: "https://www.icloud.com/share/test-mock-share") else {
                throw CloudKitServiceError.invalidArguments("Malformed mock share URL")
            }
            return url
        }
        let pvtDB = privateDatabase
        let targetID = CKRecord.ID(recordName: rootRecordID.recordName, zoneID: zoneID)

        do {
            let rootRecord = try await pvtDB.record(for: targetID)
            if let shareRef = rootRecord.share,
               let existingShare = try await pvtDB.record(for: shareRef.recordID) as? CKShare
            {
                if existingShare.publicPermission != .readWrite {
                    existingShare.publicPermission = .readWrite
                    _ = try await pvtDB.save(existingShare)
                }
                if let existingURL = existingShare.url {
                    logger.info("Found existing CKShare URL via rootRecord.share: \(existingURL, privacy: .private)")
                    return existingURL
                }
            }
        } catch let error as CKError where error.code == .unknownItem {
            // Fall through to check via query or create a new one
        } catch {
            throw error
        }

        if let existingURL = try await fetchShareURL(in: zoneID) {
            return existingURL
        }

        logger.info("No existing CKShare found for zone '\(zoneID.zoneName, privacy: .private)'. Creating new share...")
        let share = try await createShare(for: rootRecordID)
        guard let url = share.url else {
            throw CloudKitServiceError.shareFailed("Share created but URL was nil")
        }
        return url
    }

    func acceptShare(metadata: CKShare.Metadata) async throws {
        let operation = CKAcceptSharesOperation(shareMetadatas: [metadata])

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation.acceptSharesResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case let .failure(error):
                    continuation.resume(throwing: CloudKitServiceError.shareFailed(
                        "Failed to accept share: \(error)"
                    ))
                }
            }
            container.add(operation)
        }
    }

    func fetchPrivateZones() async throws -> [CKRecordZone] {
        if isTestingOrMocking {
            return []
        }
        return try await privateDatabase.allRecordZones()
    }

    func fetchSharedZones() async throws -> [CKRecordZone] {
        if isTestingOrMocking {
            return []
        }
        let sharedDB = sharedDatabase
        return try await sharedDB.allRecordZones()
    }

    func processAbandonedZonesQueue(appState: AppState) async {
        let queuedNames = appState.abandonedZoneIDs
        guard !queuedNames.isEmpty else { return }

        for zoneName in queuedNames {
            let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
            do {
                try await deleteZone(zoneID)
                appState.removeAbandonedZoneID(zoneName)
                logger.info("Successfully processed abandoned zone deletion: \(zoneName, privacy: .private)")
            } catch {
                logger.error("Retrying abandoned zone deletion failed for \(zoneName, privacy: .private): \(error, privacy: .private)")
            }
        }
    }

    func fetchShareURL(in zoneID: CKRecordZone.ID) async throws -> URL? {
        if isTestingOrMocking {
            return URL(string: "https://www.icloud.com/share/test-mock-share")
        }
        let pvtDB = privateDatabase
        let predicate = NSPredicate(value: true)
        let query = CKQuery(recordType: "cloudkit.share", predicate: predicate)

        let (matchResults, _) = try await pvtDB.records(
            matching: query,
            inZoneWith: zoneID,
            resultsLimit: 1
        )

        for (_, result) in matchResults {
            if case let .success(record) = result,
               let share = record as? CKShare
            {
                return share.url
            }
        }
        return nil
    }
}
