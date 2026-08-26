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

        // Best-effort removal of the leaver's own share participant entry. Only
        // the zone owner can mutate a `CKShare` participant list. For non-owner
        // members (Rangers/Heroes), the profile deactivation above is the authoritative
        // leave; the owner-side share reconciler and Invitations panel observe the
        // departed identity and surface it for owner-side revocation.
        if appState.isZoneOwner {
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

    /// Deactivates a member profile whose CloudKit share access was revoked at
    /// the access layer — used by the share-reconciliation observer when a
    /// participant is removed out-of-band (e.g. through the system share
    /// sheet), which the app's `Profile` records do not observe directly.
    /// Best-effort: a failure leaves the profile active and is logged
    /// privately; the in-app membership list stays as-is until a later
    /// reconciliation pass reconciles it.
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
        let nextWeek = Calendar.iso8601UTC.date(byAdding: .weekOfYear, value: 1, to: currentWeek) ?? currentWeek
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
        let isOwner = appState.isZoneOwner
        syncCoordinator?.enqueueSave(recordID: updated.id, isOwner: isOwner)
    }

    func deleteFamilyAndReset(family: Family) async throws {
        // Privileged mutation: irreversible — deleting the family is reserved
        // for the owner anchor (server-authenticated family owner). Legacy
        // families without an owner anchor fall back to the zone-owner +
        // parent-role check.
        try ActiveFamilyScopeGuard.requireActiveFamilyScope(
            family: family,
            cloudKit: cloudKit,
            appState: appState
        )

        let isOwner = await isFamilyOwner(family)
        let actingRoleIsParent = appState.currentProfile?.role.isParent ?? false
        let isAuthorized: Bool = if let anchor = family.creatorUserRecordName, anchor != "__defaultOwner__", anchor != "_defaultOwner_" {
            isOwner
        } else {
            appState.isZoneOwner && actingRoleIsParent
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
}
