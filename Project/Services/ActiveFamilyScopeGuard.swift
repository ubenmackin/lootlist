//
//  ActiveFamilyScopeGuard.swift
//  LootList
//
//  Created by Ben Mackin on 8/1/26.
//

import CloudKit
import Foundation
import os

// MARK: - ActiveFamilyScopeGuard

/// Central validation for mutation paths: ensures the record being mutated
/// belongs to the currently active family/zone/database scope. Call at the
/// top of every service mutation method.
///
/// Scope violations are deny-by-default only when the server identity is proven
/// mismatched — a stale or unresolved identity must not block the offline cache
/// fallback path.
enum ActiveFamilyScopeGuard {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "ScopeGuard")

    /// Validates that a mutation targets the profile bound to the authenticated
    /// session. Profile IDs supplied by callers are not an authorization
    /// boundary; the active session must identify the target explicitly.
    @MainActor
    static func requireAuthenticatedActiveProfile(
        _ profile: Profile,
        appState: AppState
    ) throws {
        guard appState.authStatus == .authenticated,
              let activeProfile = appState.currentProfile
        else {
            throw ScopeViolation.noActiveProfile
        }

        guard appState.isAuthenticatedActiveProfile(profile) else {
            throw ScopeViolation.profileMismatch(
                active: activeProfile.id.recordName,
                supplied: profile.id.recordName
            )
        }
    }

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

    // MARK: - Owner Anchor Resolution

    /// Owner identity resolved from the server-stamped anchor, not role.
    /// `Family.creatorUserRecordName` is the immutable owner signal; when present
    /// it dictates the database scope. Role alone is forgeable and must not drive
    /// `isZoneOwner`-equivalent decisions for sync routing.
    @MainActor
    static func resolvedIsOwner(appState: AppState?) -> Bool {
        guard let appState else { return false }
        if let creator = appState.family?.creatorUserRecordName,
           isResolvedCreatorAnchor(creator)
        {
            if let current = appState.currentProfile {
                return current.iCloudUserID.recordName == creator
            }
            logger.warning("isZoneOwner fallback: family has creator anchor but no currentProfile — using stored isZoneOwner")
        }
        return appState.isZoneOwner
    }

    /// A creator anchor is usable only when non-empty and not one of the legacy
    /// placeholder values written before the anchor existed — placeholders
    /// resolve nothing and must fall back to role-based checks.
    private static func isResolvedCreatorAnchor(_ creator: String) -> Bool {
        !creator.isEmpty && !AppConstants.Security.legacyPlaceholderCreators.contains(creator)
    }

    /// A proven mismatch between a stored creator anchor and the acting user.
    /// Unresolved anchors (nil or legacy placeholders) prove nothing either way.
    private static func isProvenCreatorMismatch(_ creator: String?, userRecordName: String) -> Bool {
        guard let creator, isResolvedCreatorAnchor(creator) else { return false }
        return creator != userRecordName
    }

    /// Validates a recovered profile against CloudKit's server-authenticated
    /// identity and the exact family/zone it claims to belong to. The profile's
    /// stored `iCloudUserID` is checked as a consistency value only; the
    /// server-stamped creator is the binding that authorizes recovery.
    ///
    /// Identity is always re-resolved fresh from CloudKit (bypassing any cached
    /// identity) — a stale cached value after an iCloud account change must not
    /// spuriously authorize or deny. Violations deny only when the mismatch is
    /// proven; an unresolved creator (legacy record) is not treated as a mismatch
    /// so the offline cache fallback remains available.
    @MainActor
    static func requireServerAuthenticatedIdentity(
        profile: Profile,
        family: Family,
        zoneID: CKRecordZone.ID,
        isOwner: Bool,
        cloudKit: any CloudKitServiceProtocol
    ) async throws {
        guard profile.id.zoneID == zoneID,
              family.id.zoneID == zoneID,
              profile.family.recordID.recordName == family.id.recordName,
              profile.family.recordID.zoneID == family.id.zoneID
        else {
            throw ScopeViolation.identityMismatch
        }

        // Fresh server identity — bypass any per-session cache so an OS-level
        // iCloud account change without an app relaunch cannot be masked by
        // a stale cached record name.
        let currentUserRecordName: String
        do {
            currentUserRecordName = try await cloudKit.currentUserRecordID().recordName
        } catch {
            throw ScopeViolation.identityUnavailable
        }

        // Primary binding: profile must belong to the current iCloud user.
        guard profile.iCloudUserID.recordName == currentUserRecordName else {
            throw ScopeViolation.identityMismatch
        }

        // Creator is checked only when resolved — nil (legacy) is not a proven mismatch.
        if isProvenCreatorMismatch(profile.creatorUserRecordName, userRecordName: currentUserRecordName) {
            throw ScopeViolation.identityMismatch
        }

        if isOwner, isProvenCreatorMismatch(family.creatorUserRecordName, userRecordName: currentUserRecordName) {
            throw ScopeViolation.identityMismatch
        }
    }
}

enum ScopeViolation: Error, LocalizedError, Equatable {
    case noActiveProfile
    case noActiveFamily
    case noActiveZone
    case profileMismatch(active: String, supplied: String)
    case familyMismatch(active: String, supplied: String)
    case zoneMismatch(active: CKRecordZone.ID, supplied: CKRecordZone.ID)
    case databaseMismatch(activeIsOwner: Bool, cloudKitIsOwner: Bool)
    case identityUnavailable
    case identityMismatch

    var errorDescription: String? {
        switch self {
        case .noActiveProfile:
            "No authenticated active profile. Please sign in first."
        case .noActiveFamily:
            "No active family. Please join or create a Guild first."
        case .noActiveZone:
            "No active zone. Please sign in first."
        case let .profileMismatch(active, supplied):
            "Profile scope mismatch: active=\(active), supplied=\(supplied)"
        case let .familyMismatch(active, supplied):
            "Family scope mismatch: active=\(active), supplied=\(supplied)"
        case let .zoneMismatch(active, supplied):
            "Zone scope mismatch: active=\(active), supplied=\(supplied)"
        case let .databaseMismatch(activeIsOwner, cloudKitIsOwner):
            "Database scope mismatch: activeIsOwner=\(activeIsOwner), cloudKitIsOwner=\(cloudKitIsOwner)"
        case .identityUnavailable:
            "The iCloud account identity could not be verified."
        case .identityMismatch:
            "The profile and family identity could not be verified for this iCloud account."
        }
    }
}
