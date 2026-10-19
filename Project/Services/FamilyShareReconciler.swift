//
//  FamilyShareReconciler.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import CloudKit
import Foundation
import os
import Synchronization

/// Reconciles active Profile cache with CloudKit share participants, deactivating departed members.
@MainActor
final class FamilyShareReconciler {
    private let familyService: FamilyService
    private let logger = Logger(category: "FamilyShare")

    private var isStarted = false
    // WHY: handle must stay cancellable from nonisolated deinit without hopping to MainActor.
    private nonisolated let observerTask = Mutex<Task<Void, Never>?>(nil)

    init(familyService: FamilyService) {
        self.familyService = familyService
    }

    deinit {
        // WHY: last resort only; owner lifecycle tears down explicitly so cancellation never depends on deinit timing.
        observerTask.withLock { $0?.cancel() }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        observerTask.withLock { stored in
            stored = Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: .syncDidComplete) {
                    guard let self else { return }
                    // WHY hop: notification sequence resumes off isolation, so awaiting re-enters MainActor before touching reconciler state.
                    await self.reconcileIfOwner()
                }
            }
        }
    }

    /// Explicit teardown for owner lifecycle; cancels the sync observer.
    func stop() {
        isStarted = false
        observerTask.withLock { $0?.cancel(); $0 = nil }
    }

    func tearDown() {
        stop()
    }

    /// Reconciles active non-owner profiles against the family's `CKShare` participant list.
    /// Membership deactivation requires positive evidence: a profile is deactivated only when
    /// every participant entry matching its iCloud identity carries `.removed` status. Pending,
    /// unresolvable, or absent identities are never evidence. Posts `.familyRosterChanged` when
    /// membership changed.
    func reconcileIfOwner() async {
        let appState = familyService.appState
        guard ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState),
              let family = appState.family
        else { return }

        // Tracks if reconciliation produced membership changes to notify observers.
        var rosterMutated = false

        do {
            let statuses = try await familyService.cloudKit.fetchShareParticipantStatuses(for: family.id)

            // WHY group by canonical identity key before any recordName filtering: pending
            // participants have no resolved user record (`recordName` nil), yet their entry
            // is presence evidence — an identity is revoked only when ALL of its entries
            // carry `.removed`.
            var entriesByIdentity: [String: [ShareParticipantStatus]] = [:]
            for status in statuses {
                guard let identityKey = status.identityKey ?? status.recordName.map({ ShareParticipantKey.recordKey(for: $0) }) else {
                    continue
                }
                entriesByIdentity[identityKey, default: []].append(status)
            }

            // WHY join unresolved pending: a re-invited member surfaces as a stale `.removed`
            // record entry plus a fresh email/phone/participantID pending entry with no
            // resolved record name yet. The pending key never matches the profile's record
            // key, yet it is presence evidence for the same identity, so it joins every
            // record group evaluation in this pass.
            let unresolvedPending = statuses.filter { $0.recordName == nil && $0.isPending && !$0.isRemoved }

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
                guard profile.role != .guildMaster, profile.iCloudUserID.recordName != currentUserRecordName else { continue }

                // A profile with no participant entry at all is never deactivated;
                // absence from the roster is negative evidence, not a revoke.
                guard let entries = entriesByIdentity[ShareParticipantKey.recordKey(for: profile.iCloudUserID.recordName)] else { continue }

                // WHY stale removed plus fresh pending is presence: the joined evidence group
                // must all be revoked before deactivating, so a re-invite pending blocks the pass.
                let evidence = entries + unresolvedPending

                // Positive evidence only: every participant entry for this identity must be revoked.
                guard evidence.allSatisfy(\.isRemoved) else { continue }

                await deactivate(profile)
                rosterMutated = true
            }
        } catch {
            logger.error("Family share reconciliation failed: \(error, privacy: .private)")
        }

        if rosterMutated {
            NotificationCenter.default.post(name: .familyRosterChanged, object: family.id.recordName)
        }
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
