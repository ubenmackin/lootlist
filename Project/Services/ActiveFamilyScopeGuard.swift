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

/// Central validation for mutation paths: ensures the record being mutated belongs to the currently
/// active family/zone/database scope.
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
    /// `appState` is optional to support non-owner bootstrap paths that synthesize
    /// before a session exists (e.g., cache-only achievement defaults) — nil
    /// intentionally routes to `.shared` (false) as a fail-safe. Owner-gated
    /// mutations must pass a non-nil session; nil there is logged/asserted in
    /// `correctedIsOwnerAndLog` so callers are audited rather than silently
    /// masking a missing session.
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

    // WHY: owner routing uses Family.creatorUserRecordName anchor via resolvedIsOwner, not role.
    @MainActor
    private static func correctedIsOwnerAndLog(
        appState: AppState?,
        logger: Logger,
        context: String
    ) -> Bool {
        if appState == nil {
            logger.error("ActiveFamilyScopeGuard nil AppState in \(context, privacy: .private) — routing to shared; audit caller if this should be owner-gated")
            assertionFailure("ActiveFamilyScopeGuard: nil AppState in \(context) — owner-gated writes must provide a session")
        }
        let isOwner = resolvedIsOwner(appState: appState)
        let storedOwner = appState?.isZoneOwner ?? false
        if isOwner != storedOwner {
            logger.warning("\(context, privacy: .private) isOwner corrected via creator anchor: stored=\(storedOwner) resolved=\(isOwner)")
        }
        return isOwner
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

    // MARK: - Corrected Owner Enqueue Helpers

    /// Centralized owner-anchor correction for sync enqueues.
    /// Computes `resolvedIsOwner`, logs a warning with `context` when the stored
    /// `isZoneOwner` diverges, then enqueues the save on the correct database scope.
    @MainActor
    static func enqueueWithCorrectedOwner(
        _ coordinator: CKSyncEngineCoordinator?,
        id: CKRecord.ID,
        appState: AppState?,
        logger: Logger,
        context: String
    ) {
        guard let coordinator else { return }
        let isOwner = correctedIsOwnerAndLog(appState: appState, logger: logger, context: context)
        coordinator.enqueueSave(recordID: id, isOwner: isOwner)
    }

    /// Overload for services that depend on the `SyncEnqueuing` seam rather than the concrete coordinator.
    @MainActor
    static func enqueueWithCorrectedOwner(
        _ coordinator: (any SyncEnqueuing)?,
        id: CKRecord.ID,
        appState: AppState?,
        logger: Logger,
        context: String
    ) {
        guard let coordinator else { return }
        let isOwner = correctedIsOwnerAndLog(appState: appState, logger: logger, context: context)
        coordinator.enqueueSave(recordID: id, isOwner: isOwner)
    }

    /// Non-optional convenience forwarding to the optional overload.
    @MainActor
    static func enqueueWithCorrectedOwner(
        _ coordinator: any SyncEnqueuing,
        id: CKRecord.ID,
        appState: AppState?,
        logger: Logger,
        context: String
    ) {
        enqueueWithCorrectedOwner(coordinator as (any SyncEnqueuing)?, id: id, appState: appState, logger: logger, context: context)
    }

    /// Batch variant — resolves the owner anchor once and enqueues all IDs on that scope.
    @MainActor
    static func batchEnqueueWithCorrectedOwner(
        _ coordinator: CKSyncEngineCoordinator?,
        ids: [CKRecord.ID],
        appState: AppState?,
        logger: Logger,
        context: String
    ) {
        guard let coordinator else { return }
        let isOwner = correctedIsOwnerAndLog(appState: appState, logger: logger, context: context)
        coordinator.batchEnqueueSave(recordIDs: ids, isOwner: isOwner)
    }

    /// Batch overload for the `SyncEnqueuing` seam.
    @MainActor
    static func batchEnqueueWithCorrectedOwner(
        _ coordinator: (any SyncEnqueuing)?,
        ids: [CKRecord.ID],
        appState: AppState?,
        logger: Logger,
        context: String
    ) {
        guard let coordinator else { return }
        let isOwner = correctedIsOwnerAndLog(appState: appState, logger: logger, context: context)
        coordinator.batchEnqueueSave(recordIDs: ids, isOwner: isOwner)
    }

    /// Delete variant for owner-corrected enqueues.
    @MainActor
    static func enqueueDeleteWithCorrectedOwner(
        _ coordinator: CKSyncEngineCoordinator?,
        id: CKRecord.ID,
        appState: AppState?,
        logger: Logger,
        context: String
    ) {
        guard let coordinator else { return }
        let isOwner = correctedIsOwnerAndLog(appState: appState, logger: logger, context: context)
        coordinator.enqueueDelete(recordID: id, isOwner: isOwner)
    }

    /// Delete overload for the `SyncEnqueuing` seam.
    @MainActor
    static func enqueueDeleteWithCorrectedOwner(
        _ coordinator: (any SyncEnqueuing)?,
        id: CKRecord.ID,
        appState: AppState?,
        logger: Logger,
        context: String
    ) {
        guard let coordinator else { return }
        let isOwner = correctedIsOwnerAndLog(appState: appState, logger: logger, context: context)
        coordinator.enqueueDelete(recordID: id, isOwner: isOwner)
    }

    /// Resolves the corrected owner anchor, logging when the stored flag diverges.
    /// Use when the caller needs the `isOwner` value for branching before enqueuing.
    @MainActor
    static func correctedIsOwner(
        appState: AppState?,
        logger: Logger,
        context: String
    ) -> Bool {
        correctedIsOwnerAndLog(appState: appState, logger: logger, context: context)
    }

    /// Validates a recovered profile against CloudKit's server-authenticated identity and the exact
    /// family/zone it claims to belong to.
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
