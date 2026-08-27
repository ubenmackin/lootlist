//
//  VerificationStatus+UI.swift
//  LootList
//
//  Created by Ben Mackin on 8/13/26.
//

import SwiftUI

extension VerificationStatus {
    var tintColor: Color {
        switch self {
        case .autoApproved, .verified:
            Color(DesignSystemConstants.Colors.primaryGreen)
        case .pending:
            Color(DesignSystemConstants.Colors.pendingAmber)
        case .rejected:
            Color(DesignSystemConstants.Colors.dangerRed)
        case .withdrawn:
            .gray
        }
    }

    var displayLabel: String {
        switch self {
        case .verified:
            "Verified"
        case .autoApproved:
            "Auto-Completed"
        case .pending:
            "Awaiting Review"
        case .rejected:
            "Rejected"
        case .withdrawn:
            "Withdrawn"
        }
    }

    var detailedDescription: String {
        switch self {
        case .autoApproved:
            "Auto-approved — money & XP earned"
        case .verified:
            "Verified by parent — money & XP earned"
        case .pending:
            "Awaiting parent verification"
        case .rejected:
            "Rejected by parent — try again"
        case .withdrawn:
            "Unsubmitted — try again"
        }
    }
}
