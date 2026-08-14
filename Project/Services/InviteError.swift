//
//  InviteError.swift
//  LootList
//
//  Created by Ben Mackin on 8/13/26.
//

import CloudKit
import Foundation

/// Static generic fallback shown when the joiner's accept/join path fails with
/// an error that does NOT indicate an invalid or expired invitation (any
/// CloudKit code outside `.unknownItem` / `.zoneNotFound` / `.invalidArguments`,
/// e.g. `.networkUnavailable`, `.serverRejectedRequest`, or `.requestRateLimited`).
/// Surfaced verbatim to the user — the underlying CloudKit error text is never
/// interpolated into it. Referenced by `OnboardingViewModel` (and its tests) as
/// the single source of the user-facing join-failure string.
let genericJoinerErrorFallback = "Could not join the family. Please try again."

/// Maps an error raised while resolving or accepting a CloudKit share
/// invitation to a user-facing message describing an invalid or expired
/// invitation, or nil when the error does not indicate that condition so
/// callers fall back to their own generic wording.
///
/// CloudKit surfaces "this share no longer resolves" in a few closely-related
/// forms depending on where it is raised, all matched symbolically here (never
/// by numeric literals or localized/domain text):
///   - resolving a share URL (`CKContainer.shareMetadata(for:)`) throws an
///     `NSError` in `CKErrorDomain`; and
///   - accepting a share (`CloudKitService.acceptShare`) throws
///     `CloudKitServiceError.shareAcceptFailed(code:message:)` with the
///     underlying `CKError.Code` preserved through the service layer.
/// The mapped codes — `.unknownItem` (the share was deleted or never existed),
/// `.zoneNotFound`, and `.invalidArguments` — all mean the invite can no longer
/// be honored, so the joiner is told the link is invalid or expired.
func friendlyInviteAcceptError(_ error: Error) -> String? {
    let invalidInvitation = "This invitation link is invalid or has expired. Please ask the Guild Master for a new invite link."

    // `CloudKitService` preserves the underlying symbolic code through the
    // service layer, so a caller that went through `acceptShare` can classify.
    if case let CloudKitServiceError.shareAcceptFailed(code, _) = error {
        return isInvalidInvitationCode(code) ? invalidInvitation : nil
    }

    // Service-level not-found states that surface when the target share/zone no
    // longer exists. The share machinery collapses `.unknownItem` into
    // `.notFound` (see `CloudKitService.wrapCKError`).
    switch error {
    case CloudKitServiceError.notFound,
         CloudKitServiceError.zoneNotFound,
         CloudKitServiceError.invalidArguments:
        return invalidInvitation
    default:
        break
    }

    // A raw CloudKit error (e.g. straight from `shareMetadata(for:)`).
    if let ckError = error as? CKError {
        return isInvalidInvitationCode(ckError.code) ? invalidInvitation : nil
    }

    // Bridge fallback for an `NSError` in the CloudKit error domain.
    let nsError = error as NSError
    if nsError.domain == CKErrorDomain {
        return isInvalidInvitationCode(CKError.Code(rawValue: nsError.code)) ? invalidInvitation : nil
    }

    // Walk the underlying-error chain in case a wrapper preserved the original
    // CloudKit error rather than the value-carrying case above.
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
        return friendlyInviteAcceptError(underlying)
    }

    return nil
}

private func isInvalidInvitationCode(_ code: CKError.Code?) -> Bool {
    switch code {
    case .unknownItem, .zoneNotFound, .invalidArguments:
        true
    default:
        false
    }
}
