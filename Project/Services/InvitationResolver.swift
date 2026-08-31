//
//  InvitationResolver.swift
//  LootList
//
//  Created by Ben Mackin on 8/16/26.
//

import CloudKit
import Foundation

/// Resolves share participant statuses into redacted invitation rows.
/// Owns the SHA-based identity token cache and the sequential anonymous label
/// counter so SwiftUI row identity stays stable and no contact data leaks to the
/// rendered panel. Pure with respect to CloudKit fetches — callers supply the
/// already-fetched `statuses` and role map. CKShare stays in the Service layer.
actor InvitationResolver {
    private let identityTokenCache = IdentityTokenCache()

    /// Counter for sequential anonymous labels in the Invitations panel.
    private var identityLabelCounter: [String: Int] = [:]

    // MARK: - Label & token computation

    /// Recomputes the sequential anonymous label mapping from the authoritative
    /// status list. Must be called before `assembleInvitations` so redacted
    /// labels are consistent within a single refresh pass.
    func computeIdentityLabels(from statuses: [ShareParticipantStatus]) {
        identityLabelCounter = [:]
        var labelIndex = 0
        for status in statuses.sorted(by: { ($0.identityKey ?? "") < ($1.identityKey ?? "") }) {
            if let key = status.identityKey {
                identityLabelCounter[key] = labelIndex
                labelIndex += 1
            }
        }
    }

    /// Assembles redacted invitation rows from the authoritative status list.
    func assembleInvitations(
        statuses: [ShareParticipantStatus],
        currentUserRecordName: String,
        activeRecordNames: Set<String>,
        inactiveIdentities: [String: String],
        roleMap: [String: UserRole]
    ) async -> [FamilyInvitation] {
        var result: [FamilyInvitation] = []

        for status in statuses {
            if let invitation = await buildStatusInvitation(
                status: status,
                currentUserRecordName: currentUserRecordName,
                activeRecordNames: activeRecordNames,
                inactiveIdentities: inactiveIdentities,
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
        roleMap: [String: UserRole]
    ) async -> FamilyInvitation? {
        let key = status.identityKey ?? status.recordName.map { "record:\($0)" }
        guard let key else { return nil }
        let targetRole = status.recordName.flatMap { roleMap[$0] } ?? roleMap[key]

        if status.recordName == currentUserRecordName
            || status.recordName == "__defaultOwner__"
            || status.recordName == CKCurrentUserDefaultName
        {
            return nil
        }
        if let recordName = status.recordName, activeRecordNames.contains(recordName) {
            return nil
        }
        if status.isRemoved {
            return await FamilyInvitation(
                id: opaqueIdentityToken(key),
                identity: redactedIdentity(for: key, recordName: status.recordName),
                statusText: "Removed",
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
                identityRecordName: recordName,
                kind: .departedMember,
                targetRole: targetRole
            )
        }
        if let recordName = status.recordName {
            return await FamilyInvitation(
                id: opaqueIdentityToken(key),
                identity: redactedIdentity(for: key, recordName: recordName),
                statusText: "Accepted",
                identityRecordName: recordName,
                kind: .pendingInvite,
                targetRole: targetRole
            )
        }
        return nil
    }

    // MARK: - Identity display & tokens

    private func redactedIdentity(for key: String, recordName: String?) -> String {
        let identityKey = recordName.map { "record:\($0)" } ?? key
        return Self.redactedIdentityLabel(for: identityKey, counter: identityLabelCounter)
    }

    /// Generates a stable, non-PII SHA256 token for row identification.
    /// Delegates to the actor-isolated cache so concurrent callers serialize
    /// SHA256 computation without racing on a plain dictionary.
    private func opaqueIdentityToken(_ value: String) async -> String {
        await identityTokenCache.token(for: value)
    }

    /// Produces a redacted, distinguishable display label without leaking contact data.
    private static func redactedIdentityLabel(for identityKey: String, counter: [String: Int] = [:]) -> String {
        if let number = counter[identityKey] {
            return "Guild Member \(number + 1)"
        }
        return "Guild Member"
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
