//
//  AuthenticationCoordinator.swift
//  LootList
//
//  Created by Ben Mackin on 9/8/26.
//

import CloudKit
import Foundation
import os

/// Owns CloudKit zone discovery and session recovery; AppState stays observable state only.
@MainActor
final class AuthenticationCoordinator {
    private static let logger = Logger(category: "Security")
    private var logger: Logger {
        Self.logger
    }

    private weak var appState: AppState?

    private let discoveryCoordinator = DiscoveryCoordinator()

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Session Clearing

    func clearSession() {
        guard let appState else { return }
        let previousFamilyRecordName = appState.sessionStorage.familyRecordName
        resetInMemoryState()
        if let previousFamilyRecordName {
            appState.cacheService?.purgeFamily(recordName: previousFamilyRecordName)
            Task {
                await appState.backgroundCacheActor?.purgeFamily(recordName: previousFamilyRecordName)
            }
        }
        appState.sessionStorage.clearSessionKeys()
        NotificationCenter.default.post(name: .didClearSession, object: nil)
    }

    func clearSessionAsync() async {
        guard let appState else { return }
        let previousFamilyRecordName = appState.sessionStorage.familyRecordName
        resetInMemoryState()
        if let previousFamilyRecordName {
            appState.cacheService?.purgeFamily(recordName: previousFamilyRecordName)
            await appState.backgroundCacheActor?.purgeFamily(recordName: previousFamilyRecordName)
        }
        appState.sessionStorage.clearSessionKeys()
        NotificationCenter.default.post(name: .didClearSession, object: nil)
    }

    func clearSessionAndCloudKitScope(cloudKit: any CloudKitServiceProtocol, syncCoordinator: CKSyncEngineCoordinator? = nil) {
        cloudKit.activeFamilyZoneID = nil
        cloudKit.activeIsOwner = false
        syncCoordinator?.resetState()
        clearSession()
    }

    func clearSessionAndCloudKitScopeAsync(cloudKit: any CloudKitServiceProtocol, syncCoordinator: CKSyncEngineCoordinator? = nil) async {
        cloudKit.activeFamilyZoneID = nil
        cloudKit.activeIsOwner = false
        syncCoordinator?.resetState()
        await clearSessionAsync()
    }

    func resetInMemoryState() {
        guard let appState else { return }
        appState.authStatus = .onboarding
        appState.currentProfile = nil
        appState.family = nil
        appState.familyZoneID = nil
        appState.isZoneOwner = false
    }

    // MARK: - Session Restoration

    func restoreSession(cloudKit: any CloudKitServiceProtocol) async {
        guard let appState else { return }
        guard let persisted = appState.sessionStorage.loadPersistedSession() else {
            guard appState.authStatus == .checkingCloudData || appState.authStatus == .restoringSession else { return }
            await appState.authStateMachine.transition(.restoreFailed)
            await discoverExistingCloudState(cloudKit: cloudKit)
            return
        }

        let profileRecordName = persisted.profileRecordName
        let familyRecordName = persisted.familyRecordName
        let zoneID = persisted.zoneID
        let zoneOwnerName = zoneID.ownerName
        let isOwner = persisted.isZoneOwner

        appState.isZoneOwner = isOwner
        cloudKit.activeFamilyZoneID = zoneID
        cloudKit.activeIsOwner = isOwner
        // WHY register before fetch: a cold launch without a prior sync hits zoneNotFound otherwise.
        if isOwner {
            do {
                try await cloudKit.ensureZoneExists(zoneID)
            } catch {
                logger.warning("ensureZoneExists failed during restore for zone '\(zoneID.zoneName, privacy: .private)': \(error, privacy: .private) — proceeding to fetch")
            }
        }
        let db = cloudKit.database(isOwner: isOwner)

        let profileID = CKRecord.ID(recordName: profileRecordName, zoneID: zoneID)
        let familyID = CKRecord.ID(recordName: familyRecordName, zoneID: zoneID)

        do {
            async let fetchedProfile = cloudKit.fetch(Profile.self, id: profileID, using: db)
            async let fetchedFamily = cloudKit.fetch(Family.self, id: familyID, using: db)
            let (profile, familyResult) = try await (fetchedProfile, fetchedFamily)
            // WHY fresh identity: a stale iCloud identity after account change must not authorize the session.
            try await ActiveFamilyScopeGuard.requireServerAuthenticatedIdentity(
                profile: profile,
                family: familyResult,
                zoneID: zoneID,
                isOwner: isOwner,
                cloudKit: cloudKit
            )

            // WHY family before zoneID: the zone notification must see a consistent family.
            appState.family = familyResult
            appState.currentProfile = profile
            let resolvedOwner = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState)
            appState.isZoneOwner = resolvedOwner
            if resolvedOwner != isOwner {
                appState.sessionStorage.isZoneOwner = resolvedOwner
                cloudKit.activeIsOwner = resolvedOwner
            }
            appState.familyZoneID = zoneID

            appState.authStatus = .authenticated
            await appState.authStateMachine.send(.sessionRestored)
        } catch {
            await handleRestorationError(
                error: error,
                profileRecordName: profileRecordName,
                familyRecordName: familyRecordName,
                zoneID: zoneID,
                zoneOwnerName: zoneOwnerName,
                isOwner: isOwner,
                cloudKit: cloudKit
            )
        }
    }

    private func handleRestorationError(
        error: Error,
        profileRecordName: String,
        familyRecordName: String,
        zoneID: CKRecordZone.ID,
        zoneOwnerName: String,
        isOwner: Bool,
        cloudKit: any CloudKitServiceProtocol
    ) async {
        guard let appState else { return }
        logger.error("Session restoration failed: \(error, privacy: .private)")
        if error is ScopeViolation {
            await handleScopeViolation(
                profileRecordName: profileRecordName,
                familyRecordName: familyRecordName,
                zoneID: zoneID,
                zoneOwnerName: zoneOwnerName,
                isOwner: isOwner,
                cloudKit: cloudKit
            )
            return
        }

        let isUnrecoverable = await isRestorationErrorUnrecoverable(
            error: error,
            isOwner: isOwner,
            familyRecordName: familyRecordName,
            zoneID: zoneID,
            cloudKit: cloudKit
        )

        if isUnrecoverable {
            if !isOwner,
               let cloudKitError = error as? CloudKitServiceError,
               case .zoneNotFound = cloudKitError
            {
                logger.info("Shared family zone is unavailable — clearing revoked hero session")
                appState.familyAccessRevokedSignal = UUID()
                await clearSessionAndCloudKitScopeAsync(cloudKit: cloudKit)
                await appState.authStateMachine.transition(.restoreFailed)
                await discoverExistingCloudState(cloudKit: cloudKit)
                return
            }
            if !restoreFromCache(profileRecordName: profileRecordName, familyRecordName: familyRecordName, zoneID: zoneID, isOwner: isOwner) {
                logger.info("Unrecoverable CloudKit session error and no cache available — clearing session and running cloud discovery")
                await clearSessionAndCloudKitScopeAsync(cloudKit: cloudKit)
                await appState.authStateMachine.transition(.restoreFailed)
                await discoverExistingCloudState(cloudKit: cloudKit)
            }
        } else if !restoreFromCache(profileRecordName: profileRecordName, familyRecordName: familyRecordName, zoneID: zoneID, isOwner: isOwner) {
            appState.authStatus = .offlineEmptyCache
        }
    }

    private func handleScopeViolation(
        profileRecordName: String,
        familyRecordName: String,
        zoneID: CKRecordZone.ID,
        zoneOwnerName: String,
        isOwner: Bool,
        cloudKit: any CloudKitServiceProtocol
    ) async {
        guard let appState else { return }
        let isPlaceholderOwner = ActiveFamilyScopeGuard.isPlaceholderOwner(zoneOwnerName)
        if isPlaceholderOwner || isOwner {
            logger.info("ScopeViolation with placeholder/stale owner \(zoneOwnerName, privacy: .private) — clearing stale session and rediscovering")
            await clearSessionAndCloudKitScopeAsync(cloudKit: cloudKit)
            await appState.authStateMachine.transition(.restoreFailed)
            await discoverExistingCloudState(cloudKit: cloudKit)
            return
        }
        if restoreFromCache(profileRecordName: profileRecordName, familyRecordName: familyRecordName, zoneID: zoneID, isOwner: isOwner) {
            return
        }
        await clearSessionAndCloudKitScopeAsync(cloudKit: cloudKit)
        await appState.authStateMachine.transition(.restoreFailed)
        await discoverExistingCloudState(cloudKit: cloudKit)
    }

    private func isRestorationErrorUnrecoverable(
        error: Error,
        isOwner: Bool,
        familyRecordName: String,
        zoneID: CKRecordZone.ID,
        cloudKit: any CloudKitServiceProtocol
    ) async -> Bool {
        if let ckErr = error as? CloudKitServiceError {
            switch ckErr {
            case .notFound, .invalidArguments, .zoneNotFound:
                return true
            default:
                break
            }
        }
        let reachable = await Self.isZoneReachable(
            cloudKit: cloudKit,
            familyRecordName: familyRecordName,
            zoneID: zoneID
        )
        return isOwner && !reachable
    }

    // MARK: - Cache Fallback

    @discardableResult
    private func restoreFromCache(
        profileRecordName: String,
        familyRecordName: String,
        zoneID: CKRecordZone.ID,
        isOwner: Bool
    ) -> Bool {
        guard let appState,
              let cache = appState.cacheService
        else { return false }

        let cachedProfile = cache.fetchProfile(recordName: profileRecordName, family: familyRecordName)
        let cachedFamily = cache.fetchFamily(recordName: familyRecordName)
        guard let cachedProfile, let cachedFamily else {
            return false
        }

        // WHY family before zoneID: the zone notification must not fire before family context exists.
        appState.family = cachedFamily.toFamily(zoneID: zoneID)
        appState.currentProfile = cachedProfile.toProfile(zoneID: zoneID)
        let resolvedOwner = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState)
        appState.isZoneOwner = resolvedOwner
        if resolvedOwner != isOwner {
            appState.sessionStorage.isZoneOwner = resolvedOwner
        }
        appState.familyZoneID = zoneID
        appState.authStatus = .authenticated
        logger.info("Session restored from local cache (offline mode)")
        let freshnessScope: CKDatabase.Scope = DatabaseScopeResolver.scope(isOwner: resolvedOwner)
        cache.markCacheFresh(familyRecordName: familyRecordName, type: .family, scope: freshnessScope)
        cache.markCacheFresh(familyRecordName: familyRecordName, type: .profile, scope: freshnessScope)
        return true
    }

    private static func isZoneReachable(
        cloudKit: any CloudKitServiceProtocol,
        familyRecordName: String,
        zoneID: CKRecordZone.ID
    ) async -> Bool {
        let service = FamilyDiscoveryService()
        return await service.isZoneReachable(
            cloudKit: cloudKit,
            familyRecordName: familyRecordName,
            zoneID: zoneID
        )
    }

    // MARK: - Cloud State Discovery

    func discoverExistingCloudState(cloudKit: any CloudKitServiceProtocol) async {
        guard let appState else { return }
        let canStart = await discoveryCoordinator.begin()
        if !canStart {
            logger.info("Cloud state discovery joined the in-progress discovery")
            await discoveryCoordinator.wait()
            return
        }

        defer {
            Task { await self.discoveryCoordinator.finish() }
        }

        if case .detectedPreviousFamily = appState.authStatus {
            return
        }
        if case .authenticated = appState.authStatus {
            return
        }

        if appState.family != nil, appState.currentProfile != nil {
            appState.authStatus = .authenticated
            return
        }

        let service = appState.discoveryService ?? FamilyDiscoveryService()
        let result = await service.discoverExistingCloudState(cloudKit: cloudKit)
        switch result {
        case let .owner(candidate):
            appState.authStatus = .detectedPreviousFamily(family: candidate.family, profile: candidate.profile, zoneID: candidate.zoneID, isOwner: true)
        case let .hero(candidate):
            appState.authStatus = .detectedPreviousFamily(family: candidate.family, profile: candidate.profile, zoneID: candidate.zoneID, isOwner: false)
        case .none:
            appState.authStatus = .onboarding
        }
    }

    func resolveCurrentUserRecordID(cloudKit: any CloudKitServiceProtocol) async -> CKRecord.ID? {
        guard let appState else {
            let service = FamilyDiscoveryService()
            return await service.resolveCurrentUserRecordID(cloudKit: cloudKit)
        }
        let service = appState.discoveryService ?? FamilyDiscoveryService()
        return await service.resolveCurrentUserRecordID(cloudKit: cloudKit)
    }

    static func activeSharedHeroProfiles(
        cloudKit: any CloudKitServiceProtocol,
        userRecordID: CKRecord.ID?,
        zoneID: CKRecordZone.ID
    ) async -> [Profile] {
        let service = FamilyDiscoveryService()
        return await service.activeSharedHeroProfiles(
            cloudKit: cloudKit,
            userRecordID: userRecordID,
            zoneID: zoneID
        )
    }

    static func sharedZoneFamily(
        cloudKit: any CloudKitServiceProtocol,
        zoneID: CKRecordZone.ID
    ) async -> Family? {
        let service = FamilyDiscoveryService()
        return await service.sharedZoneFamily(cloudKit: cloudKit, zoneID: zoneID)
    }

    // MARK: - Detected Family Decisions

    func acceptDetectedFamily(familyCache: FamilyCache, profileCache: ProfileCache, zoneID: CKRecordZone.ID, isOwner: Bool, cloudKit: any CloudKitServiceProtocol) async {
        await acceptDetectedFamily(
            family: familyCache.toFamily(zoneID: zoneID),
            profile: profileCache.toProfile(zoneID: zoneID),
            zoneID: zoneID,
            isOwner: isOwner,
            cloudKit: cloudKit
        )
    }

    func acceptDetectedFamily(
        familyCache: FamilyCache,
        profileCache: ProfileCache,
        zoneName: String,
        zoneOwnerName: String,
        isOwner: Bool,
        cloudKit: any CloudKitServiceProtocol
    ) async {
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: zoneOwnerName)
        await acceptDetectedFamily(
            familyCache: familyCache,
            profileCache: profileCache,
            zoneID: zoneID,
            isOwner: isOwner,
            cloudKit: cloudKit
        )
    }

    func acceptDetectedFamily(family: Family, profile: Profile, zoneID: CKRecordZone.ID, isOwner _: Bool, cloudKit: any CloudKitServiceProtocol) async {
        guard let appState else { return }
        appState.family = family
        appState.currentProfile = profile
        let resolvedOwner = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState)
        do {
            try await ActiveFamilyScopeGuard.requireServerAuthenticatedIdentity(
                profile: profile,
                family: family,
                zoneID: zoneID,
                isOwner: resolvedOwner,
                cloudKit: cloudKit
            )
        } catch {
            logger.error("Rejected family recovery because server identity validation failed: \(error, privacy: .private)")
            appState.family = nil
            appState.currentProfile = nil
            appState.authStatus = .onboarding
            return
        }
        appState.sessionStorage.save(profile: profile, family: family, zoneID: zoneID, isOwner: resolvedOwner)
        appState.isZoneOwner = resolvedOwner
        appState.familyZoneID = zoneID
        cloudKit.activeFamilyZoneID = zoneID
        cloudKit.activeIsOwner = resolvedOwner
        appState.authStatus = .authenticated
    }

    func rejectDetectedFamily(familyCache: FamilyCache, profileCache: ProfileCache, zoneID: CKRecordZone.ID, isOwner: Bool, cloudKit: any CloudKitServiceProtocol) async {
        await rejectDetectedFamily(
            family: familyCache.toFamily(zoneID: zoneID),
            profile: profileCache.toProfile(zoneID: zoneID),
            zoneID: zoneID,
            isOwner: isOwner,
            cloudKit: cloudKit
        )
    }

    func rejectDetectedFamily(
        familyCache: FamilyCache,
        profileCache: ProfileCache,
        zoneName: String,
        zoneOwnerName: String,
        isOwner: Bool,
        cloudKit: any CloudKitServiceProtocol
    ) async {
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: zoneOwnerName)
        await rejectDetectedFamily(
            familyCache: familyCache,
            profileCache: profileCache,
            zoneID: zoneID,
            isOwner: isOwner,
            cloudKit: cloudKit
        )
    }

    func rejectDetectedFamily(family _: Family, profile: Profile, zoneID: CKRecordZone.ID, isOwner: Bool, cloudKit: any CloudKitServiceProtocol) async {
        guard let appState else { return }
        if isOwner {
            appState.sessionStorage.addAbandonedZoneID(zoneID.zoneName)
            do {
                try await cloudKit.deleteZone(zoneID)
                appState.sessionStorage.removeAbandonedZoneID(zoneID.zoneName)
            } catch {
                logger.error("Failed to delete zone on rejection: \(error, privacy: .private)")
            }
        } else {
            var deactivated = profile
            deactivated.isActive = false
            let db = cloudKit.database(isOwner: false)
            do {
                _ = try await cloudKit.save(deactivated, in: zoneID, using: db)
            } catch {
                logger.error("Failed to save profile deactivation on rejection: \(error, privacy: .private)")
            }
        }
        await clearSessionAndCloudKitScopeAsync(cloudKit: cloudKit)
    }

    // MARK: - Sign Out

    func signOutAndDiscover(cloudKit: any CloudKitServiceProtocol, syncCoordinator: CKSyncEngineCoordinator? = nil) async {
        guard let appState else { return }
        let alreadyInFlight = await discoveryCoordinator.isRunning
        if alreadyInFlight {
            await clearSessionAndCloudKitScopeAsync(cloudKit: cloudKit, syncCoordinator: syncCoordinator)
            appState.authStatus = .checkingCloudData
            await discoveryCoordinator.wait()
            appState.authStatus = .checkingCloudData
            await discoverExistingCloudState(cloudKit: cloudKit)
            return
        }
        await clearSessionAndCloudKitScopeAsync(cloudKit: cloudKit, syncCoordinator: syncCoordinator)
        appState.authStatus = .checkingCloudData
        await discoverExistingCloudState(cloudKit: cloudKit)
    }
}

private actor DiscoveryCoordinator {
    private var isInFlight = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    var isRunning: Bool {
        isInFlight
    }

    func begin() -> Bool {
        if isInFlight {
            return false
        }
        isInFlight = true
        return true
    }

    func finish() {
        isInFlight = false
        let pending = Array(waiters.values)
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }

    func wait() async {
        guard isInFlight else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func cancelWaiter(id: UUID) {
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.resume()
        }
    }
}
