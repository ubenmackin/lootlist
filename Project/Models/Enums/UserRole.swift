//
//  UserRole.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation

enum UserRole: String, Codable, CaseIterable, Sendable {
    case guildMaster

    case ranger

    case hero

    var displayName: String {
        switch self {
        case .guildMaster: "Guild Master"
        case .ranger: "Ranger"
        case .hero: "Hero"
        }
    }

    var iconSystemName: String {
        switch self {
        case .guildMaster: "crown.fill"
        case .ranger: "person.2.fill"
        case .hero: "figure.and.child.holdinghands"
        }
    }

    var isParent: Bool {
        switch self {
        case .guildMaster, .ranger: true
        case .hero: false
        }
    }

    var genericRoleName: String {
        switch self {
        case .guildMaster, .ranger: "Parent"
        case .hero: "Child"
        }
    }

    /// User-facing invite copy — Ranger renders as Co-Parent outside the stored raw value.
    var inviteDisplayName: String {
        // WHY derived: invite copy matches displayName except Ranger, which invites as Co-Parent.
        if self == .ranger {
            return "Co-Parent"
        }
        return displayName
    }
}

// MARK: - CKShare Role Token

extension UserRole {
    /// Role token embedded in CKShare titles to recover target role on join.
    var shareTitleSuffix: String {
        switch self {
        case .guildMaster: ": Guild"
        case .ranger: ": Co-Parent Invitation"
        case .hero: ": Hero Invitation"
        }
    }

    /// Decodes the role token from CKShare title, defaulting to .hero when absent.
    static func fromShareTitle(_ title: String?) -> UserRole? {
        guard let title else { return nil }
        return allCases.first { title.hasSuffix($0.shareTitleSuffix) }
    }
}
