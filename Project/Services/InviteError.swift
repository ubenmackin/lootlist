//
//  InviteError.swift
//  LootList
//
//  Created by Ben Mackin on 8/13/26.
//

import CloudKit
import Foundation

/// Generic error message displayed when family join fails due to transient or system errors.
let genericJoinerErrorFallback = "Could not join the family. Please try again."

/// Maps share resolution/acceptance errors to a user-friendly invalid/expired invitation message.
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
