//
//  VerificationStatus.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation

enum VerificationStatus: String, Sendable, CaseIterable, Codable {
    case autoApproved

    case pending

    case verified

    case rejected

    /// A pending submission that the completer (or a parent) unsubmitted. The
    /// completion record is never deleted — the state transition keeps log
    /// entries append-only — and a withdrawn log no longer occupies a quest
    /// completion slot, so the hero may submit the quest again.
    case withdrawn

    var displayName: String {
        switch self {
        case .autoApproved: "Auto-Approved"
        case .pending: "Pending"
        case .verified: "Verified"
        case .rejected: "Rejected"
        case .withdrawn: "Withdrawn"
        }
    }

    var iconSystemName: String {
        switch self {
        case .autoApproved: "checkmark.seal.fill"
        case .pending: "hourglass"
        case .verified: "checkmark.seal.fill"
        case .rejected: "xmark.octagon.fill"
        case .withdrawn: "arrow.uturn.backward.circle.fill"
        }
    }

    /// Whether a completion in this state still holds one of the quest's
    /// completion slots. Approved and pending logs reserve a slot; rejected
    /// (by a parent) and withdrawn (by the completer) logs do not, so both
    /// keep the quest gated open for another submission.
    var countsTowardCompletion: Bool {
        switch self {
        case .autoApproved, .pending, .verified: true
        case .rejected, .withdrawn: false
        }
    }
}
