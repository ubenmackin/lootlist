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

    /// Pending submission unsubmitted by the completer or parent (keeps history append-only).
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

    /// Whether completion holds a slot (approved/pending reserve slots; rejected/withdrawn do not).
    var countsTowardCompletion: Bool {
        switch self {
        case .autoApproved, .pending, .verified: true
        case .rejected, .withdrawn: false
        }
    }
}
