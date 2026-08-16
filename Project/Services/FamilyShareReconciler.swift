//
//  FamilyShareReconciler.swift
//  LootList
//
//  Created by Ben Mackin on 2026-08-12.
//

import CloudKit
import Foundation
import os

/// Keeps the app-domain membership layer (active `Profile` records) reconciled
/// with the CloudKit access layer (the family `CKShare` participant list).
/// When a participant is removed out-of-band — for example by the Guild Master
/// through the system share sheet, which revokes raw iCloud zone access without
/// touching the app's `Profile` records — the matching active `Profile` is
/// deactivated so the in-app members list reflects who can actually read/write
/// the shared zone.
///
/// Trigger: the app's existing `.syncDidComplete` notification, which
/// `CKSyncEngineCoordinator` posts at the end of every sync pass. The system share sheet is
/// integral to `UICloudSharingController` and exposes no retained callback to
/// the presenting app here, so the sync-complete hook is the closest available
/// signal that the server-side participant list may have changed; the
/// reconciler then re-reads the authoritative participant list directly.
///
/// The reconciler is owner-only: only the zone owner can query the family's
/// `CKShare` participant list from the private database, so only the owner's
/// device carries it. It is best-effort and idempotent (already-inactive
/// profiles are skipped), so repeated passes are harmless.
///
/// Deactivation is deliberately conservative about participant-list absence:
/// CloudKit propagates share-membership changes asynchronously, so a freshly
/// joined member can be briefly absent from the owner's participant list. A
/// profile is therefore deactivated only when (a) the participant is present
/// with an explicitly revoked (`.removed`) status, or (b) the identity has been
/// observed absent for two consecutive passes. Absence marks persist in
/// `UserDefaults` keyed per family + identity — the same persistence pattern as
/// `CKSyncEngine`'s state serialization — so a relaunch cannot reset the count and a
/// transient propagation window cannot deactivate a live member.
///
/// The pass aborts entirely when the current user's CloudKit identity cannot be
/// resolved: without it the self-exclusion guard cannot run, and proceeding
/// would risk deactivating the current user's own profile (deny-by-default,
/// matching `FamilyService.isFamilyOwner`).
@MainActor
final class FamilyShareReconciler {
    private let familyService: FamilyService
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "FamilyShare")

    /// Passes an identity must be observed absent from the participant list
    /// before its profile is deactivated, riding out CloudKit's asynchronous
    /// propagation for freshly joined members.
    private let absenceThreshold = AppConstants.CloudKit.shareAbsenceThreshold

    private var isStarted = false
    private var observerTask: Task<Void, Never>?

    init(familyService: FamilyService, defaults: UserDefaults = .standard) {
        self.familyService = familyService
        self.defaults = defaults
    }

    deinit {
        observerTask?.cancel()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        observerTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .syncDidComplete) {
                guard let self else { return }
                await self.reconcileIfOwner()
            }
        }
    }

    func stop() {
        isStarted = false
        observerTask?.cancel()
        observerTask = nil
    }

    /// Owner-only reconciliation of active non-owner profiles against the
    /// family's current `CKShare` participant list. Internal so tests can drive
    /// the pass directly; production invokes it from the `.syncDidComplete`
    /// observer in `start()`.
    func reconcileIfOwner() async {
        let appState = familyService.appState
        guard appState.isZoneOwner,
              let family = appState.family
        else { return }

        do {
            let statuses = try await familyService.cloudKit.fetchShareParticipantStatuses(for: family.id)
            let revokedIdentities = Set(statuses.filter(\.isRemoved).compactMap(\.recordName))
            let presentIdentities = Set(statuses.filter { !$0.isRemoved }.compactMap(\.recordName))

            // The self-exclusion guard cannot run without the current user's
            // identity, so resolution failure aborts the whole pass: proceeding
            // would risk deactivating the current user's own profile. This is
            // the same deny-by-default posture as `FamilyService.isFamilyOwner`.
            let currentUserRecordName: String
            do {
                currentUserRecordName = try await familyService.cloudKit.currentUserRecordID().recordName
            } catch {
                logger.error("Family share reconciliation skipped: could not resolve current user identity (\(error, privacy: .private))")
                return
            }

            let profiles = await (try? familyService.fetchAllProfilesForFamily(family)) ?? []
            for profile in profiles where profile.isActive {
                // The Guild Master (owner) is never a participant, and the
                // current user's own profile must never be self-deactivated, so
                // both are excluded regardless of participant-list membership.
                guard profile.role != .guildMaster else { continue }
                guard profile.iCloudUserID.recordName != currentUserRecordName else { continue }

                let identityKey = profile.iCloudUserID.recordName
                if revokedIdentities.contains(identityKey) {
                    // The participant was explicitly revoked (`.removed`) on the
                    // share: the revoke is authoritative, so the profile is
                    // deactivated immediately regardless of convergence marks.
                    clearAbsenceMark(family: family, identityKey: identityKey)
                    await deactivate(profile)
                    continue
                }
                if presentIdentities.contains(identityKey) {
                    // Live access is confirmed; clear any accumulated absence
                    // marks (a fresh join may have propagated late).
                    clearAbsenceMark(family: family, identityKey: identityKey)
                    continue
                }
                // Absent from the participant list. Absence alone is not
                // treated as revocation — CloudKit propagation is asynchronous,
                // so a single observation could be a lagging fresh join. Only a
                // second consecutive pass (or an explicit `.removed` status
                // above) deactivates.
                let observedAbsences = recordAbsence(family: family, identityKey: identityKey)
                if observedAbsences >= absenceThreshold {
                    clearAbsenceMark(family: family, identityKey: identityKey)
                    await deactivate(profile)
                }
            }
        } catch {
            logger.error("Family share reconciliation failed: \(error, privacy: .private)")
        }
    }

    /// Increments and returns the consecutive-absence count for an identity,
    /// persisted in `UserDefaults` so the count survives relaunches and stays
    /// scoped per family + identity (mirroring `CKSyncEngine`'s state serialization).
    private func recordAbsence(family: Family, identityKey: String) -> Int {
        let key = absenceMarkerKey(familyRecordName: family.id.recordName, identityKey: identityKey)
        let count = defaults.integer(forKey: key) + 1
        defaults.set(count, forKey: key)
        return count
    }

    private func clearAbsenceMark(family: Family, identityKey: String) {
        defaults.removeObject(forKey: absenceMarkerKey(familyRecordName: family.id.recordName, identityKey: identityKey))
    }

    private func absenceMarkerKey(familyRecordName: String, identityKey: String) -> String {
        "shareReconciler.absence.\(familyRecordName).\(identityKey)"
    }

    private func deactivate(_ profile: Profile) async {
        do {
            try await familyService.deactivateMemberAfterShareRevocation(profile)
            logger.info("Deactivated \(profile.displayName, privacy: .private) — share access was revoked")
        } catch {
            logger.error("Failed to deactivate \(profile.displayName, privacy: .private) after share revocation: \(error, privacy: .private)")
        }
    }
}
