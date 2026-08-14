//
//  InviteErrorTests.swift
//  LootList
//
//  Created by Ben Mackin on 8/13/26.
//

import CloudKit
import Foundation
@testable import LootList
import Testing

/// Covers `friendlyInviteAcceptError`, the shared error→friendly-message
/// mapping used by the joiner onboarding path (OnboardingViewModel and
/// FamilyJoinView) when resolving/accepting a CloudKit share invitation.
/// Guards the symbolic `CKError.Code` classification against regression back
/// to brittle numeric-literal or error-text probes.
struct InviteErrorTests {
    private static let friendlyMessage = "This invitation link is invalid or has expired. Please ask the Guild Master for a new invite link."

    // MARK: - shareAcceptFailed (acceptShare path, code preserved)

    @Test(arguments: [CKError.Code.unknownItem, .zoneNotFound, .invalidArguments])
    func `accept share not found codes map to invalid invitation`(code: CKError.Code) {
        let error = CloudKitServiceError.shareAcceptFailed(code: code, message: "Failed to accept share")
        #expect(friendlyInviteAcceptError(error) == Self.friendlyMessage)
    }

    @Test
    func `accept share without code falls through to nil`() {
        let error = CloudKitServiceError.shareAcceptFailed(code: nil, message: "The share invitation could not be accepted.")
        #expect(friendlyInviteAcceptError(error) == nil)
    }

    @Test
    func `accept share non not found code falls through to nil`() {
        let error = CloudKitServiceError.shareAcceptFailed(code: .networkUnavailable, message: "The share invitation could not be accepted.")
        #expect(friendlyInviteAcceptError(error) == nil)
    }

    // MARK: - No-leak guarantees (accept/join user-facing strings)

    /// Guards remediation of the raw-CKError leak: for any code outside the
    /// invalid-invitation set, callers fall back to the static generic message,
    /// which must never contain CloudKit/raw error text.
    @Test
    func `non invalid invitation code falls back to static generic message`() {
        let raw = "Failed to accept share: <CKErrorDomain: 20> \"serverRejectedRequest\"; _containerIdentifier=iCloud.com.volcrypt.lootlist; _zoneName=_zone; _recordName=record_abc"
        let error = CloudKitServiceError.shareAcceptFailed(code: .serverRejectedRequest, message: raw)
        #expect(friendlyInviteAcceptError(error) == nil)
        #expect(genericJoinerErrorFallback == "Could not join the family. Please try again.")
        #expect(!genericJoinerErrorFallback.contains("CloudKit"))
        #expect(!genericJoinerErrorFallback.contains("_containerIdentifier"))
        #expect(!genericJoinerErrorFallback.contains(raw))
    }

    /// `shareAcceptFailed.errorDescription` must be a static, generic string —
    /// it must not interpolate the `message` argument (which previously carried
    /// raw `CKError` text) or any other raw CloudKit detail.
    @Test
    func `shareAcceptFailed error description is static and omits raw error`() {
        let raw = "Failed to accept share: <CKErrorDomain: 9> \"networkUnavailable\"; _zoneName=_zone; _recordName=record_abc"
        let error = CloudKitServiceError.shareAcceptFailed(code: .networkUnavailable, message: raw)
        let description = error.errorDescription
        #expect(description == "Could not accept the share invitation.")
        #expect(!(description ?? "").contains(raw))
        #expect(!(description ?? "").contains("networkUnavailable"))
    }

    // MARK: - Message-carrying `errorDescription` cases are static

    /// Guards remediation of the raw-CKError leak across the remaining
    /// message-carrying cases (`.underlying`, `.shareFailed`,
    /// `.zoneSetupFailed`, `.invalidArguments`, `.notFound`): each
    /// `errorDescription` must be a static generic string that never embeds
    /// the raw associated value. The associated value is preserved for
    /// `.private` logging but must never reach the user-facing description.
    @Test(arguments: [
        "underlying",
        "shareFailed",
        "zoneSetupFailed",
        "invalidArguments",
        "notFound"
    ])
    func `message carrying error description is static`(_ kind: String) {
        let raw = "<CKErrorDomain: 20> \"serverRejectedRequest\"; _containerIdentifier=iCloud.com.volcrypt.lootlist; _zoneName=_zone; _recordName=record_abc"
        let error: CloudKitServiceError = switch kind {
        case "underlying": .underlying(raw)
        case "shareFailed": .shareFailed(raw)
        case "zoneSetupFailed": .zoneSetupFailed(raw)
        case "invalidArguments": .invalidArguments(raw)
        default: .notFound(raw)
        }
        let description = error.errorDescription
        #expect(!(description ?? "").contains(raw))
        #expect(!(description ?? "").contains("CKErrorDomain"))
        #expect(!(description ?? "").contains("_containerIdentifier"))
    }

    /// The sanitized descriptions must not be empty, so the toast fallback
    /// always has a generic message to show.
    @Test
    func `message carrying error descriptions are non empty`() {
        #expect(CloudKitServiceError.underlying("x").errorDescription?.isEmpty == false)
        #expect(CloudKitServiceError.shareFailed("x").errorDescription?.isEmpty == false)
        #expect(CloudKitServiceError.zoneSetupFailed("x").errorDescription?.isEmpty == false)
        #expect(CloudKitServiceError.invalidArguments("x").errorDescription?.isEmpty == false)
    }

    // MARK: - Service-level not-found states

    @Test
    func `service not found states map to invalid invitation`() {
        #expect(friendlyInviteAcceptError(CloudKitServiceError.notFound("share")) == Self.friendlyMessage)
        #expect(friendlyInviteAcceptError(CloudKitServiceError.zoneNotFound) == Self.friendlyMessage)
        #expect(friendlyInviteAcceptError(CloudKitServiceError.invalidArguments("share")) == Self.friendlyMessage)
    }

    // MARK: - Raw CloudKit NSError (shareMetadata path)

    @Test
    func `raw unknown item NS error maps to invalid invitation`() {
        let nsError = NSError(domain: CKErrorDomain, code: CKError.Code.unknownItem.rawValue)
        #expect(friendlyInviteAcceptError(nsError) == Self.friendlyMessage)
    }

    @Test
    func `unrelated cloud kit code falls through to nil`() {
        let nsError = NSError(domain: CKErrorDomain, code: CKError.Code.networkUnavailable.rawValue)
        #expect(friendlyInviteAcceptError(nsError) == nil)
    }

    // MARK: - Non-CloudKit errors

    @Test
    func `generic error falls through to nil`() {
        enum Generic: Error { case boom }
        #expect(friendlyInviteAcceptError(Generic.boom) == nil)
        #expect(friendlyInviteAcceptError(CloudKitServiceError.accountUnavailable) == nil)
    }
}
