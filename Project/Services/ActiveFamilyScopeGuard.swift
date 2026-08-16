//
//  ActiveFamilyScopeGuard.swift
//  LootList
//
//  Created by Ben Mackin on 8/1/26.
//

import CloudKit
import Foundation

/// Central validation for mutation paths: ensures the record being mutated
/// belongs to the currently active family/zone/database scope. Call at the
/// top of every service mutation method.
enum ActiveFamilyScopeGuard {
    /// Validates that the supplied `familyRecordName` matches the active
    /// family on `AppState`. Throws `ScopeViolation.familyMismatch` if the
    /// check fails.
    @MainActor
    static func requireActiveFamily(
        familyRecordName: String,
        appState: AppState
    ) throws {
        let activeFamilyName = appState.family?.id.recordName ?? appState.currentProfile?.family.recordID.recordName
        guard let active = activeFamilyName else {
            throw ScopeViolation.noActiveFamily
        }
        guard active == familyRecordName else {
            throw ScopeViolation.familyMismatch(
                active: active,
                supplied: familyRecordName
            )
        }
    }

    /// Full scope validation: family, zone, and database.
    @MainActor
    static func requireActiveFamilyScope(
        familyRecordName: String,
        zoneID: CKRecordZone.ID,
        appState: AppState,
        cloudKit: any CloudKitServiceProtocol
    ) throws {
        try requireActiveFamily(familyRecordName: familyRecordName, appState: appState)

        let activeZone = appState.familyZoneID ?? appState.currentProfile?.id.zoneID
        guard let activeZoneID = activeZone else {
            throw ScopeViolation.noActiveZone
        }
        guard activeZoneID == zoneID else {
            throw ScopeViolation.zoneMismatch(
                active: activeZoneID,
                supplied: zoneID
            )
        }

        if let ckActiveZone = cloudKit.activeFamilyZoneID {
            guard ckActiveZone == zoneID else {
                throw ScopeViolation.zoneMismatch(
                    active: ckActiveZone,
                    supplied: zoneID
                )
            }
            if let appStateZone = appState.familyZoneID, appStateZone == zoneID {
                guard cloudKit.activeIsOwner == appState.isZoneOwner else {
                    throw ScopeViolation.databaseMismatch(
                        activeIsOwner: appState.isZoneOwner,
                        cloudKitIsOwner: cloudKit.activeIsOwner
                    )
                }
            }
        }
    }

    /// Full scope validation convenience taking a `Family` model.
    @MainActor
    static func requireActiveFamilyScope(
        family: Family,
        cloudKit: any CloudKitServiceProtocol,
        appState: AppState
    ) throws {
        try requireActiveFamilyScope(
            familyRecordName: family.id.recordName,
            zoneID: family.id.zoneID,
            appState: appState,
            cloudKit: cloudKit
        )
    }

    /// Convenience that extracts family record name from a `CKRecord.Reference`.
    @MainActor
    static func requireActiveFamily(
        familyRef: CKRecord.Reference,
        appState: AppState
    ) throws {
        try requireActiveFamily(
            familyRecordName: familyRef.recordID.recordName,
            appState: appState
        )
    }

    /// Full scope validation convenience taking a `CKRecord.Reference` and `CKRecordZone.ID`.
    @MainActor
    static func requireActiveFamilyScope(
        familyRef: CKRecord.Reference,
        zoneID: CKRecordZone.ID,
        appState: AppState,
        cloudKit: any CloudKitServiceProtocol
    ) throws {
        try requireActiveFamilyScope(
            familyRecordName: familyRef.recordID.recordName,
            zoneID: zoneID,
            appState: appState,
            cloudKit: cloudKit
        )
    }
}

enum ScopeViolation: Error, LocalizedError, Equatable {
    case noActiveFamily
    case noActiveZone
    case familyMismatch(active: String, supplied: String)
    case zoneMismatch(active: CKRecordZone.ID, supplied: CKRecordZone.ID)
    case databaseMismatch(activeIsOwner: Bool, cloudKitIsOwner: Bool)

    var errorDescription: String? {
        switch self {
        case .noActiveFamily:
            "No active family. Please join or create a Guild first."
        case .noActiveZone:
            "No active zone. Please sign in first."
        case let .familyMismatch(active, supplied):
            "Family scope mismatch: active=\(active), supplied=\(supplied)"
        case let .zoneMismatch(active, supplied):
            "Zone scope mismatch: active=\(active), supplied=\(supplied)"
        case let .databaseMismatch(activeIsOwner, cloudKitIsOwner):
            "Database scope mismatch: activeIsOwner=\(activeIsOwner), cloudKitIsOwner=\(cloudKitIsOwner)"
        }
    }
}
