//
//  InvitationResolver.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import CloudKit
import Foundation

/// Resolves CloudKit share participants and statuses into redacted invitation rows.
/// Owns the SHA-based identity token cache and the sequential anonymous label
/// counter so SwiftUI row identity stays stable and no contact data leaks to the
/// rendered panel. Pure with respect to CloudKit fetches — callers supply the
/// already-fetched `statuses`, `participants`, and role map.
struct InvitationResolver {
    /// Actor-isolated token cache that serializes SHA256 generation and survives
    /// `@MainActor` re-entrancy during async refresh.
    private let identityTokenCache = IdentityTokenCache()

    /// Counter for sequential anonymous labels in the Invitations panel.
    private var identityLabelCounter: [String: Int] = [:]

    // MARK: - Label & token computation

    /// Recomputes the sequential anonymous label mapping from the authoritative
    /// status list. Must be called before `assembleInvitations` so redacted
    /// labels are consistent within a single refresh pass.
    mutating func computeIdentityLabels(from statuses: [ShareParticipantStatus]) {
        identityLabelCounter = [:]
        var labelIndex = 0
        for status in statuses.sorted(by: { ($0.identityKey ?? "") < ($1.identityKey ?? "") }) {
            if let key = status.identityKey {
                identityLabelCounter[key] = labelIndex
                labelIndex += 1
            }
        }
    }

    /// Assembles redacted invitation rows from the authoritative status list and
    /// the live participant objects. Handles status-driven rows (including
    /// `.removed` markers) and falls back to participant objects for pending
    /// invites without an established identity.
    func assembleInvitations(
        statuses: [ShareParticipantStatus],
        participants: [CKShare.Participant],
        currentUserRecordName: String,
        activeRecordNames: Set<String>,
        inactiveIdentities: [String: String],
        participantByRecordName: [String: CKShare.Participant],
        roleMap: [String: UserRole]
    ) async -> [FamilyInvitation] {
        var result: [FamilyInvitation] = []
        var handledRecordNames = Set<String>()
        var handledKeys = Set<String>()

        for status in statuses {
            let key = status.identityKey ?? status.recordName.map { "record:\($0)" }
            guard let key else { continue }
            handledKeys.insert(key)
            if let recordName = status.recordName {
                handledRecordNames.insert(recordName)
            }
            if let invitation = await buildStatusInvitation(
                status: status,
                currentUserRecordName: currentUserRecordName,
                activeRecordNames: activeRecordNames,
                inactiveIdentities: inactiveIdentities,
                participantByRecordName: participantByRecordName,
                roleMap: roleMap
            ) {
                result.append(invitation)
            }
        }

        for participant in participants {
            if let invitation = await buildParticipantInvitation(
                participant: participant,
                currentUserRecordName: currentUserRecordName,
                handledRecordNames: handledRecordNames,
                handledKeys: handledKeys,
                roleMap: roleMap
            ) {
                result.append(invitation)
            }
        }

        return result
    }

    // MARK: - Private assembly helpers

    private func buildStatusInvitation(
        status: ShareParticipantStatus,
        currentUserRecordName: String,
        activeRecordNames: Set<String>,
        inactiveIdentities: [String: String],
        participantByRecordName: [String: CKShare.Participant],
        roleMap: [String: UserRole]
    ) async -> FamilyInvitation? {
        let key = status.identityKey ?? status.recordName.map { "record:\($0)" }
        guard let key else { return nil }
        let participant = status.recordName.flatMap { participantByRecordName[$0] }
        let targetRole = status.recordName.flatMap { roleMap[$0] } ?? roleMap[key]

        if participant?.role == .owner || status.recordName == currentUserRecordName {
            return nil
        }
        if let recordName = status.recordName, activeRecordNames.contains(recordName) {
            return nil
        }
        if status.isRemoved {
            return await FamilyInvitation(
                id: opaqueIdentityToken(key),
                identity: identityDisplay(for: key, recordName: status.recordName, participant: participant),
                statusText: "Removed",
                participant: participant,
                identityRecordName: status.recordName,
                kind: .removedIdentity,
                targetRole: targetRole
            )
        }
        if let recordName = status.recordName, let displayName = inactiveIdentities[recordName] {
            return await FamilyInvitation(
                id: opaqueIdentityToken(key),
                identity: displayName,
                statusText: "Left the guild — revoke share access",
                participant: participant,
                identityRecordName: recordName,
                kind: .departedMember,
                targetRole: targetRole
            )
        }
        if let recordName = status.recordName {
            return await FamilyInvitation(
                id: opaqueIdentityToken(key),
                identity: identityDisplay(for: key, recordName: recordName, participant: participant),
                statusText: "Accepted",
                participant: participant,
                identityRecordName: recordName,
                kind: .pendingInvite,
                targetRole: targetRole
            )
        }
        return nil
    }

    private func buildParticipantInvitation(
        participant: CKShare.Participant,
        currentUserRecordName: String,
        handledRecordNames: Set<String>,
        handledKeys: Set<String>,
        roleMap: [String: UserRole]
    ) async -> FamilyInvitation? {
        let recordName = participant.userIdentity.userRecordID?.recordName
        if participant.role == .owner || (recordName != nil && recordName == currentUserRecordName) {
            return nil
        }
        if let recordName, handledRecordNames.contains(recordName) {
            return nil
        }
        let pKey = ShareParticipantKey.key(for: participant)
        if let pKey, handledKeys.contains(pKey) {
            return nil
        }
        let targetRole = recordName.flatMap { roleMap[$0] } ?? pKey.flatMap { roleMap[$0] }
        let isRemoved = participant.acceptanceStatus == .removed
        return await FamilyInvitation(
            id: invitationID(for: participant),
            identity: participantIdentityDisplay(participant),
            statusText: isRemoved ? "Removed" : Self.invitationStatusText(participant.acceptanceStatus),
            participant: participant,
            identityRecordName: recordName,
            kind: isRemoved ? .removedIdentity : .pendingInvite,
            targetRole: targetRole
        )
    }

    // MARK: - Identity display & tokens

    private func identityDisplay(for key: String, recordName: String?, participant: CKShare.Participant?) -> String {
        if let participant {
            return participantIdentityDisplay(participant)
        }
        let identityKey = recordName.map { "record:\($0)" } ?? key
        return Self.redactedIdentityLabel(for: identityKey, counter: identityLabelCounter)
    }

    private func invitationID(for participant: CKShare.Participant) async -> String {
        if let key = ShareParticipantKey.key(for: participant) {
            return await opaqueIdentityToken(key)
        }
        return await opaqueIdentityToken("object:\(ObjectIdentifier(participant))")
    }

    /// Generates a stable, non-PII SHA256 token for row identification.
    /// Delegates to the actor-isolated cache so concurrent callers serialize
    /// SHA256 computation without racing on a plain dictionary.
    private func opaqueIdentityToken(_ value: String) async -> String {
        await identityTokenCache.token(for: value)
    }

    private func participantIdentityDisplay(_ participant: CKShare.Participant) -> String {
        guard let key = ShareParticipantKey.key(for: participant) else {
            return "Invited member"
        }
        return Self.redactedIdentityLabel(for: key, counter: identityLabelCounter)
    }

    /// Produces a redacted, distinguishable display label without leaking contact data.
    private static func redactedIdentityLabel(for identityKey: String, counter: [String: Int] = [:]) -> String {
        if let number = counter[identityKey] {
            return "Guild Member \(number + 1)"
        }
        return "Guild Member"
    }

    private static func invitationStatusText(_ status: CKShare.ParticipantAcceptanceStatus) -> String {
        switch status {
        case .pending: "Invited"
        case .accepted: "Accepted"
        case .removed: "Removed"
        case .unknown: "Pending"
        @unknown default: "Invited"
        }
    }

    // MARK: - Test support

    /// Snapshot of cached tokens for inspection in tests.
    var cachedTokens: [String: String] {
        get async {
            await identityTokenCache.cachedTokens()
        }
    }

    /// Convenience async snapshot for explicit await call sites.
    func cachedTokensSnapshot() async -> [String: String] {
        await identityTokenCache.cachedTokens()
    }

    /// Snapshot of label counters for inspection in tests.
    var labelCounters: [String: Int] {
        identityLabelCounter
    }
}
