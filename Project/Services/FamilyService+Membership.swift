//
//  FamilyService+Membership.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation
import os

extension FamilyService {
    // MARK: - Membership & Lifecycle Management

    func leaveFamily(profile: Profile) async throws {
        try await unassignActiveQuests(for: profile)
        try await deactivateProfile(profile)

        // Deactivates member profile and removes share participant entry (owner or self-leave).
        let isOwnerForShare = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState)
        let storedOwnerForShare = appState.isZoneOwner
        if isOwnerForShare != storedOwnerForShare {
            logger.warning("FamilyService.leaveFamily isOwner corrected via creator anchor: stored=\(storedOwnerForShare) resolved=\(isOwnerForShare)")
        }
        if isOwnerForShare {
            let family = await family(for: profile)
            let rootRecordID = family?.id ?? profile.family.recordID
            do {
                try await cloudKit.removeParticipant(iCloudUserRecordName: profile.iCloudUserID.recordName, from: rootRecordID)
            } catch {
                logger.error("Failed to remove leaving member's share participant: \(error, privacy: .private)")
            }
        }

        appState.clearSessionAndCloudKitScope(cloudKit: cloudKit, syncCoordinator: syncCoordinator)
    }

    @discardableResult
    func kickMember(profile: Profile) async throws -> FamilyKickResult {
        // Privileged mutation: removing a member from the guild is reserved for
        // the owner anchor (server-authenticated family owner). Legacy families
        // without an owner anchor fall back to the parent-role check.
        let family = try await requireParentOrOwner(for: profile)
        try await unassignActiveQuests(for: profile)
        try await deactivateProfile(profile)

        // Best-effort participant removal; returns partial status if share revocation fails.
        let rootRecordID = family.id
        do {
            try await cloudKit.removeParticipant(iCloudUserRecordName: profile.iCloudUserID.recordName, from: rootRecordID)
            return .fully
        } catch {
            logger.error("Failed to remove kicked member's share participant: \(error, privacy: .private)")
            return .partialRevocationFailed(
                error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }

    /// Deactivates member profile after share revocation observed out-of-band.
    func deactivateMemberAfterShareRevocation(_ profile: Profile) async throws {
        try await deactivateProfile(profile)
    }

    func unassignActiveQuests(for profile: Profile) async throws {
        guard let family = appState.family else { return }
        let payoutDay = profile.payoutDay ?? family.payoutDay
        let currentWeek = WeekMath.startOfWeek(for: Date(), payoutDay: payoutDay)

        #if DEBUG
            let questStart = QuestService.startOfWeek(for: Date(), payoutDay: payoutDay)
            assert(
                currentWeek == questStart,
                "QuestService.startOfWeek and WeekMath.startOfWeek diverged: \(currentWeek) vs \(questStart)"
            )
        #endif

        let currentQuests: [Quest]
        do {
            currentQuests = try await questService.fetchActiveQuests(profile: profile, weekOf: currentWeek)
        } catch {
            logger.warning("Failed to fetch current-week quests for share revocation cleanup: \(error, privacy: .private)")
            toastManager?.show(
                message: "Couldn't verify the member's quests before removal. Please try again.",
                type: .error
            )
            throw FamilyServiceError.persistenceFailed
        }
        let nextWeek = WeekMath.weekStart(byAddingWeeks: 1, to: currentWeek)
        let nextQuests: [Quest]
        do {
            nextQuests = try await questService.fetchActiveQuests(profile: profile, weekOf: nextWeek)
        } catch {
            logger.warning("Failed to fetch next-week quests for share revocation cleanup: \(error, privacy: .private)")
            toastManager?.show(
                message: "Couldn't verify the member's quests before removal. Please try again.",
                type: .error
            )
            throw FamilyServiceError.persistenceFailed
        }

        var unassignErrors: [Error] = []
        for quest in currentQuests + nextQuests {
            do {
                try await questService.unassignQuest(quest)
            } catch {
                logger
                    .error(
                        "Failed to unassign quest '\(quest.id.recordName, privacy: .private)' for profile '\(profile.id.recordName, privacy: .private)': \(error, privacy: .private)"
                    )
                unassignErrors.append(error)
            }
        }

        if !unassignErrors.isEmpty {
            let message = "Couldn't remove \(unassignErrors.count) quest(s) from the member. Please try again."
            toastManager?.show(message: message, type: .error)
            throw FamilyServiceError.persistenceFailed
        }
    }

    func deactivateProfile(_ profile: Profile) async throws {
        // Privileged mutation: a parent may deactivate any member. A member may
        // only deactivate their own profile (self-service leave); deactivating
        // another member's profile is parent-only.
        let actingProfile = appState.currentProfile
        let isSelfDeactivation = actingProfile?.id == profile.id
        guard isSelfDeactivation || actingProfile?.role.isParent == true else {
            throw FamilyServiceError.unauthorized
        }

        var updated = profile
        updated.isActive = false

        await cacheService?.upsertProfile(updated)
        if appState.currentProfile?.id == updated.id {
            appState.currentProfile = updated
        }
        // WHY: owner routing uses Family.creatorUserRecordName anchor via resolvedIsOwner, not role.
        let isOwner = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState)
        let storedOwner = appState.isZoneOwner
        if isOwner != storedOwner {
            logger.warning("FamilyService.deactivateProfile isOwner corrected via creator anchor: stored=\(storedOwner) resolved=\(isOwner)")
        }
        syncCoordinator?.enqueueSave(recordID: updated.id, isOwner: isOwner)
    }

    func deleteFamilyAndReset(family: Family) async throws {
        // Irreversible family deletion reserved for server-authenticated family creator.
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            family: family,
            cloudKit: cloudKit,
            appState: appState
        )

        let isOwner = await isFamilyOwner(family)
        let actingRoleIsParent = appState.currentProfile?.role.isParent ?? false
        // WHY: owner check uses Family.creatorUserRecordName anchor via resolvedIsOwner, not role.
        let resolvedOwner = ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState)
        let storedOwnerFallback = appState.isZoneOwner
        if resolvedOwner != storedOwnerFallback {
            logger.warning("FamilyService.deleteFamilyAndReset fallback isOwner corrected via creator anchor: stored=\(storedOwnerFallback) resolved=\(resolvedOwner)")
        }
        let isAuthorized: Bool = if let anchor = family.creatorUserRecordName, anchor != "__defaultOwner__", anchor != "_defaultOwner_" {
            isOwner
        } else {
            resolvedOwner && actingRoleIsParent
        }
        guard isAuthorized else {
            throw FamilyServiceError.unauthorized
        }
        // 1. Delete the CloudKit zone if this user owns it, or add to abandoned queue if offline.
        let targetZoneID = family.id.zoneID
        do {
            try await cloudKit.deleteZone(targetZoneID)
        } catch {
            logger.error("Could not delete zone immediately; queueing abandoned zone: \(error, privacy: .private)")
            appState.addAbandonedZoneID(targetZoneID.zoneName)
        }

        // 2. Clear CloudKit active state, purge family cache, reset sync coordinator, and clear session.
        appState.clearSessionAndCloudKitScope(cloudKit: cloudKit, syncCoordinator: syncCoordinator)
    }

    // MARK: - Session & Detected Family Facades (CloudKit isolation)

    // WHY: Views must not hold CloudKitService or CKSyncEngineCoordinator; this facade keeps CloudKit scope and session transitions inside the service layer.
    func acceptDetectedFamily(familyCache: FamilyCache, profileCache: ProfileCache, zoneIDString: String, isOwner: Bool) async {
        await appState.acceptDetectedFamily(familyCache: familyCache, profileCache: profileCache, zoneIDString: zoneIDString, isOwner: isOwner, cloudKit: cloudKit)
    }

    func acceptDetectedFamily(family: Family, profile: Profile, zoneID: CKRecordZone.ID, isOwner: Bool) async {
        await appState.acceptDetectedFamily(family: family, profile: profile, zoneID: zoneID, isOwner: isOwner, cloudKit: cloudKit)
    }

    func rejectDetectedFamily(familyCache: FamilyCache, profileCache: ProfileCache, zoneIDString: String, isOwner: Bool) async {
        await appState.rejectDetectedFamily(familyCache: familyCache, profileCache: profileCache, zoneIDString: zoneIDString, isOwner: isOwner, cloudKit: cloudKit)
    }

    func signOutAndDiscover() async {
        await appState.signOutAndDiscover(cloudKit: cloudKit, syncCoordinator: syncCoordinator)
    }

    func clearSessionAndScope() {
        appState.clearSessionAndCloudKitScope(cloudKit: cloudKit, syncCoordinator: syncCoordinator)
    }
}
