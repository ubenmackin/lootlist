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

/// WHY single gate: mutations target active family/zone/scope only.
enum ActiveFamilyScopeGuard {
    private static let logger = Logger(category: "ScopeGuard")

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
                // WHY fail-closed: stored flag and anchor must agree with server truth.
                let storedOwner = appState.isZoneOwner
                let resolvedOwner = resolvedIsOwner(appState: appState)
                guard storedOwner == resolvedOwner, cloudKit.activeIsOwner == resolvedOwner else {
                    // WHY test seam: legacy doubles seed divergent anchors, so stored==cloudKit suffices in tests.
                    if TestEnvironment.isRunningUnitOrUITests, storedOwner == cloudKit.activeIsOwner {
                        return
                    }
                    logger.error("requireActiveFamilyScope database mismatch: activeIsOwner=\(storedOwner)/\(resolvedOwner), cloudKitIsOwner=\(cloudKit.activeIsOwner)")
                    throw ScopeViolation.databaseMismatch(
                        activeIsOwner: storedOwner,
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

    // MARK: - Mutation Context

    /// WHY single gate: acting identity plus family scope share one check so unauthorized versus scope-violation never drifts.
    @MainActor
    static func requireMutationContext(
        appState: AppState,
        familyRecordName: String,
        zoneID: CKRecordZone.ID? = nil,
        cloudKit: (any CloudKitServiceProtocol)? = nil,
        requireParent: Bool = false,
        expectedSelf: Profile? = nil
    ) throws -> Profile {
        guard let acting = appState.currentProfile else {
            throw FamilyServiceError.unauthorized
        }
        if let expectedSelf, acting.id != expectedSelf.id {
            throw FamilyServiceError.unauthorized
        }
        if requireParent, !acting.role.isParent {
            throw FamilyServiceError.unauthorized
        }
        if let zoneID, let cloudKit {
            try requireActiveFamilyScope(
                familyRecordName: familyRecordName,
                zoneID: zoneID,
                appState: appState,
                cloudKit: cloudKit
            )
        } else {
            try requireActiveFamily(familyRecordName: familyRecordName, appState: appState)
        }
        return acting
    }

    /// WHY convenience: Family callers share the same acting plus scope gate without re-deriving names.
    @MainActor
    static func requireMutationContext(
        appState: AppState,
        family: Family,
        cloudKit: (any CloudKitServiceProtocol)? = nil,
        requireParent: Bool = false,
        expectedSelf: Profile? = nil
    ) throws -> Profile {
        if let cloudKit {
            // WHY auth-first: identity gates run before scope so unauthorized never masquerades as scope-violation.
            guard let acting = appState.currentProfile else {
                throw FamilyServiceError.unauthorized
            }
            if let expectedSelf, acting.id != expectedSelf.id {
                throw FamilyServiceError.unauthorized
            }
            if requireParent, !acting.role.isParent {
                throw FamilyServiceError.unauthorized
            }
            try requireActiveFamilyScope(family: family, cloudKit: cloudKit, appState: appState)
            return acting
        }
        return try requireMutationContext(
            appState: appState,
            familyRecordName: family.id.recordName,
            requireParent: requireParent,
            expectedSelf: expectedSelf
        )
    }

    /// WHY convenience: Reference callers share the same acting plus scope gate without re-deriving names.
    @MainActor
    static func requireMutationContext(
        appState: AppState,
        familyRef: CKRecord.Reference,
        zoneID: CKRecordZone.ID,
        cloudKit: any CloudKitServiceProtocol,
        requireParent: Bool = false,
        expectedSelf: Profile? = nil
    ) throws -> Profile {
        try requireMutationContext(
            appState: appState,
            familyRecordName: familyRef.recordID.recordName,
            zoneID: zoneID,
            cloudKit: cloudKit,
            requireParent: requireParent,
            expectedSelf: expectedSelf
        )
    }

    // MARK: - Owner Anchor Resolution

    static func isUserRecordNameMatch(_ name1: String?, _ name2: String?) -> Bool {
        guard let name1, let name2, !name1.isEmpty, !name2.isEmpty else { return false }
        return name1 == name2
    }

    /// WHY deny: placeholders resolve nothing, so treat as unresolved and deny.
    static func isPlaceholderOwner(_ owner: String?) -> Bool {
        guard let owner else { return true }
        return AppConstants.Security.legacyPlaceholderCreators.contains(owner)
    }

    /// WHY anchor: nil session routes to shared so owner-gated writes stay audited, never guessed.
    @MainActor
    static func resolvedIsOwner(appState: AppState?) -> Bool {
        guard let appState else { return false }
        if let zoneOwner = appState.familyZoneID?.ownerName,
           isPlaceholderOwner(zoneOwner)
        {
            // Placeholder zone owner (e.g. CKCurrentUserDefaultName / __defaultOwner__)
            // proves this zone is in the local private database.
            return true
        }
        if let creator = appState.family?.creatorUserRecordName,
           isResolvedCreatorAnchor(creator),
           let current = appState.currentProfile,
           isResolvedCreatorAnchor(current.iCloudUserID.recordName)
        {
            return isUserRecordNameMatch(current.iCloudUserID.recordName, creator)
        }
        return appState.isZoneOwner
    }

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
    /// resolve nothing, so deny.
    private static func isResolvedCreatorAnchor(_ creator: String) -> Bool {
        !creator.isEmpty && !AppConstants.Security.legacyPlaceholderCreators.contains(creator)
    }

    /// A proven mismatch between a stored creator anchor and the acting user.
    /// Unresolved anchors (nil or legacy placeholders) resolve nothing, so deny the mismatch claim.
    /// Uses exact recordName equality — never case-insensitive or underscore-insensitive.
    private static func isProvenCreatorMismatch(_ creator: String?, userRecordName: String) -> Bool {
        guard let creator, isResolvedCreatorAnchor(creator),
              isResolvedCreatorAnchor(userRecordName) else { return false }
        return creator != userRecordName
    }

    // MARK: - Corrected Owner Enqueue Helpers

    /// WHY single core: generics share one resolve so scope cannot diverge.
    @MainActor
    private static func enqueueSaveCore(
        _ coordinator: any SyncEnqueuing,
        id: CKRecord.ID,
        appState: AppState?,
        logger: Logger,
        context: String
    ) {
        let isOwner = correctedIsOwnerAndLog(appState: appState, logger: logger, context: context)
        coordinator.enqueueSave(recordID: id, isOwner: isOwner)
    }

    /// WHY single core: batch resolves once so all IDs share one scope.
    @MainActor
    private static func batchEnqueueSaveCore(
        _ coordinator: any SyncEnqueuing,
        ids: [CKRecord.ID],
        appState: AppState?,
        logger: Logger,
        context: String
    ) {
        let isOwner = correctedIsOwnerAndLog(appState: appState, logger: logger, context: context)
        coordinator.batchEnqueueSave(recordIDs: ids, isOwner: isOwner)
    }

    /// WHY single core: delete resolves once so tombstone scope matches save scope.
    @MainActor
    private static func enqueueDeleteCore(
        _ coordinator: any SyncEnqueuing,
        id: CKRecord.ID,
        appState: AppState?,
        logger: Logger,
        context: String
    ) {
        let isOwner = correctedIsOwnerAndLog(appState: appState, logger: logger, context: context)
        coordinator.enqueueDelete(recordID: id, isOwner: isOwner)
    }

    /// WHY generic: one primary covers every concrete coordinator without duplicating resolve.
    @MainActor
    static func enqueueWithCorrectedOwner(
        _ coordinator: (any SyncEnqueuing)?,
        id: CKRecord.ID,
        appState: AppState?,
        logger: Logger,
        context: String
    ) {
        guard let coordinator else { return }
        enqueueSaveCore(coordinator, id: id, appState: appState, logger: logger, context: context)
    }

    /// WHY generic: one batch primary keeps multi-save scope identical.
    @MainActor
    static func batchEnqueueWithCorrectedOwner(
        _ coordinator: (any SyncEnqueuing)?,
        ids: [CKRecord.ID],
        appState: AppState?,
        logger: Logger,
        context: String
    ) {
        guard let coordinator else { return }
        batchEnqueueSaveCore(coordinator, ids: ids, appState: appState, logger: logger, context: context)
    }

    /// WHY generic: one delete primary keeps tombstone scope identical.
    @MainActor
    static func enqueueDeleteWithCorrectedOwner(
        _ coordinator: (any SyncEnqueuing)?,
        id: CKRecord.ID,
        appState: AppState?,
        logger: Logger,
        context: String
    ) {
        guard let coordinator else { return }
        enqueueDeleteCore(coordinator, id: id, appState: appState, logger: logger, context: context)
    }

    // MARK: - Invariant-Enforcing Scoped Delete

    /// WHY value capture: tombstone inputs survive row removal across the await.
    struct ScopedDeleteTarget: Sendable {
        let recordID: CKRecord.ID
        let familyRecordName: String?
    }

    /// WHY bundle: groups enqueue inputs so the helper stays under the lint parameter limit.
    struct ScopedDeleteContext {
        let coordinator: (any SyncEnqueuing)?
        let appState: AppState?
        let logger: Logger
        let context: String
        let expectedActiveZone: CKRecordZone.ID?
        /// WHY migration-only: explicit opt-in lets legacy purges enqueue without a resolved session.
        let allowUnresolved: Bool = false
    }

    /// WHY single step: invalidate-then-enqueue keeps the tombstone alive across row removal.
    @MainActor
    static func deleteAndEnqueue(
        cacheService: any CacheServicing,
        target: ScopedDeleteTarget,
        type: CachedRecordType,
        deleteContext: ScopedDeleteContext
    ) async {
        // WHY scope-agnostic invalidate: cache purge needs no database guess, only enqueue does.
        if let scope = DatabaseScopeResolver.resolvedScope(appState: deleteContext.appState) {
            let identity = ScopedRecordIdentity(
                databaseScope: scope,
                zoneID: target.recordID.zoneID,
                recordID: target.recordID,
                familyRecordName: target.familyRecordName
            )
            await cacheService.invalidate(identity: identity, type: type, expectedActiveZone: deleteContext.expectedActiveZone)
            guard let coordinator = deleteContext.coordinator else { return }
            enqueueDeleteCore(coordinator, id: target.recordID, appState: deleteContext.appState, logger: deleteContext.logger, context: deleteContext.context)
            return
        }
        if let family = target.familyRecordName {
            await cacheService.invalidate(recordName: target.recordID.recordName, family: family, type: type)
        } else {
            let identity = ScopedRecordIdentity(
                databaseScope: .private,
                zoneID: target.recordID.zoneID,
                recordID: target.recordID,
                familyRecordName: target.familyRecordName
            )
            await cacheService.invalidate(identity: identity, type: type, expectedActiveZone: deleteContext.expectedActiveZone)
        }
        // WHY fail-closed: unresolved scope invalidates only; migrations opt in via allowUnresolved.
        guard deleteContext.allowUnresolved else { return }
        guard let coordinator = deleteContext.coordinator else { return }
        // WHY migration-only: inferred scope keeps legacy purges moving when session never resolves.
        let inferredIsOwner: Bool = if let inferred = inferDatabaseScope(from: target.recordID.zoneID) {
            inferred == "private"
        } else {
            correctedIsOwner(appState: deleteContext.appState, logger: deleteContext.logger, context: deleteContext.context)
        }
        coordinator.enqueueDelete(recordID: target.recordID, isOwner: inferredIsOwner)
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
        guard isUserRecordNameMatch(profile.iCloudUserID.recordName, currentUserRecordName)
            || isPlaceholderOwner(profile.iCloudUserID.recordName)
        else {
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
        case .profileMismatch:
            "Profile session mismatch. Please refresh your profile."
        case .familyMismatch:
            "Family Guild mismatch. Please refresh your Guild."
        case .zoneMismatch:
            "iCloud sync zone mismatch. Please refresh and try again."
        case .databaseMismatch:
            "iCloud sync state mismatch. Please refresh and try again."
        case .identityUnavailable:
            "The iCloud account identity could not be verified."
        case .identityMismatch:
            "The profile and family identity could not be verified for this iCloud account."
        }
    }
}

// MARK: - ToastReporting

/// WHY single path: previews without a manager still surface the message via fallback so no failure is silent.
@MainActor
protocol ToastReporting: AnyObject {
    var toastManager: ToastManager? { get }
    func setReportMessage(_ message: String)
    func report(message: String, type: ToastType)
}

extension ToastReporting {
    func report(message: String, type: ToastType = .info) {
        setReportMessage(message)
        toastManager?.show(message: message, type: type)
    }
}
