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

    var isOwner: Bool {
        self == .guildMaster
    }

    var genericRoleName: String {
        switch self {
        case .guildMaster, .ranger: "Parent"
        case .hero: "Child"
        }
    }
}

// MARK: - CKShare Role Token

extension UserRole {
    /// Role token embedded in `CKShare` titles (as `"<familyName>" + suffix`)
    /// so the joiner side can recover the target role from the title field of
    /// the `CKShare` record behind the share metadata
    /// (`metadata.share[CKShare.SystemFieldKey.title]`). The exact suffix
    /// literals are the wire contract between the GM-side mint
    /// (`createShare(for:role:)`) and the joiner-side parse
    /// (`fromShareTitle(_:)`) — keep the two in sync.
    var shareTitleSuffix: String {
        switch self {
        case .guildMaster: ": Guild"
        case .ranger: ": Co-Parent Invitation"
        case .hero: ": Hero Invitation"
        }
    }

    /// Encodes the role token baked into `CKShare.title` by the GM-side
    /// invitation flow. Synchronized with the sharing service's
    /// `createShare(for:role:)` title conventions. Returns the role matching
    /// the share's title suffix, or nil for titles without a recognized role
    /// token (e.g. legacy family-name-only titles minted before role-targeted
    /// invitations) — callers fall back to `.hero` in that case.
    static func fromShareTitle(_ title: String?) -> UserRole? {
        guard let title else { return nil }
        return allCases.first { title.hasSuffix($0.shareTitleSuffix) }
    }
}
