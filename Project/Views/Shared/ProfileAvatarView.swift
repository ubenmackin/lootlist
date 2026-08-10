//
//  ProfileAvatarView.swift
//  LootList
//
//  Created by Ben Mackin on 8/8/26.
//

import CloudKit
import SwiftUI

/// Compact avatar tile shared by list/header cards that render a profile's
/// miniature avatar (small size, name/title hidden).
///
/// A `nil` profile renders the default "Hero / Adventurer" placeholder so a
/// card with a still-restoring session never shows an empty avatar.
struct ProfileAvatarView: View {
    let profile: Profile?

    var body: some View {
        AvatarView(spec: avatarSpec, size: .small, showsNameAndTitle: false)
    }

    private var avatarSpec: AvatarRenderSpec {
        guard let profile else {
            return AvatarRenderSpec(
                preset: nil,
                customAvatarImageData: nil,
                displayName: "Hero",
                levelTitle: "Adventurer",
                equippedAccessory: nil,
                avatarClass: nil,
                role: .hero
            )
        }
        return AvatarRenderSpec(
            preset: AvatarPreset.preset(forProfile: profile),
            customAvatarImageData: profile.customAvatarImageData,
            displayName: profile.displayName,
            levelTitle: XPService.title(forLevel: profile.level),
            equippedAccessory: nil,
            avatarClass: profile.avatarClass,
            role: profile.role
        )
    }
}
