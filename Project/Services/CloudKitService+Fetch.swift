//
//  CloudKitService+Fetch.swift
//  LootList
//
//  Created by Ben Mackin on August 6, 2026.
//

import CloudKit
import Foundation

/// Value mirror of `CKAccountStatus` allowing views to observe account state without importing CloudKit.
enum CloudAccountStatus: Equatable, Sendable {
    case available
    case noAccount
    case restricted
    case temporarilyUnavailable
    case couldNotDetermine

    init(_ status: CKAccountStatus) {
        switch status {
        case .available: self = .available
        case .noAccount: self = .noAccount
        case .restricted: self = .restricted
        case .temporarilyUnavailable: self = .temporarilyUnavailable
        case .couldNotDetermine: self = .couldNotDetermine
        @unknown default: self = .couldNotDetermine
        }
    }

    var displayName: String {
        switch self {
        case .available: "Available"
        case .noAccount: "No Account"
        case .restricted: "Restricted"
        case .temporarilyUnavailable: "Temporarily Unavailable"
        case .couldNotDetermine: "Could Not Determine"
        }
    }
}

extension CloudKitService {
    func fetch<T: CloudKitRecord>(_: T.Type,
                                  id: CKRecord.ID,
                                  using db: CKDatabase? = nil) async throws -> T
    {
        guard let targetDB = db ?? activeFamilyDatabase else {
            logger.error("CloudKitService.fetch rejected: no target database provided and no activeFamilyDatabase available")
            throw CloudKitServiceError.accountUnavailable
        }
        let targetID: CKRecord.ID = {
            if id.zoneID.zoneName != CKRecordZone.default().zoneID.zoneName {
                return id
            }
            if let activeZone = activeFamilyZoneID {
                return CKRecord.ID(recordName: id.recordName, zoneID: activeZone)
            }
            return id
        }()
        let record = try await retrying {
            try await targetDB.record(for: targetID)
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
