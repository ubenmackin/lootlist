//
//  FamilyShareReconciler.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import CloudKit
import Foundation
import os

/// Reconciles active Profile cache with CloudKit share participants, deactivating departed members.
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

    /// Reconciles active non-owner profiles against the family's `CKShare` participant list.
    /// Posts `.familyRosterChanged` if membership changes occurred.
    func reconcileIfOwner() async {
        let appState = familyService.appState
        guard ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState),
              let family = appState.family
        else { return }

        // Tracks if reconciliation produced membership changes to notify observers.
        var rosterMutated = false

        do {
            let statuses = try await familyService.cloudKit.fetchShareParticipantStatuses(for: family.id)
            let revokedIdentities = Set(statuses.filter(\.isRemoved).compactMap(\.recordName))
            let presentIdentities = Set(statuses.filter { !$0.isRemoved }.compactMap(\.recordName))

            // Self-exclusion guard ensures current user's own profile is never auto-deactivated.
            let currentUserRecordName: String
            do {
                currentUserRecordName = try await familyService.cloudKit.currentUserRecordID().recordName
            } catch {
                logger.error("Family share reconciliation skipped: could not resolve current user identity (\(error, privacy: .private))")
                return
            }

            let profiles: [Profile]
            do {
                profiles = try await familyService.fetchAllProfilesForFamily(family)
            } catch {
                logger.error("Family share reconciliation skipped: could not fetch profiles (\(error, privacy: .private))")
                return
            }
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
                    rosterMutated = true
                    continue
                }
                if presentIdentities.contains(identityKey) {
                    // Live access is confirmed; clear any accumulated absence
                    // marks (a fresh join may have propagated late).
                    if defaults.integer(forKey: absenceMarkerKey(familyRecordName: family.id.recordName, identityKey: identityKey)) > 0 {
                        clearAbsenceMark(family: family, identityKey: identityKey)
                        rosterMutated = true
                    }
                    continue
                }
                // Deactivates profiles absent from share participants after verifying missing share access.
                let observedAbsences = recordAbsence(family: family, identityKey: identityKey)
                if observedAbsences >= absenceThreshold {
                    clearAbsenceMark(family: family, identityKey: identityKey)
                    await deactivate(profile)
                    rosterMutated = true
                }
            }
        } catch {
            logger.error("Family share reconciliation failed: \(error, privacy: .private)")
        }

        if rosterMutated {
            NotificationCenter.default.post(name: .familyRosterChanged, object: family.id.recordName)
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
