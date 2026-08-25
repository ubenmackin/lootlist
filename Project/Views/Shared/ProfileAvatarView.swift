//
//  ProfileAvatarView.swift
//  LootList
//
//  Created by Ben Mackin on 8/8/26.
//

import SwiftData
import SwiftUI

/// Compact avatar tile shared by list/header cards that render a profile's
/// miniature avatar (small size, name/title hidden).
///
/// A `nil` profile renders the default "Hero" placeholder so a
/// card with a still-restoring session never shows an empty avatar.
struct ProfileAvatarView: View {
    let profileCache: ProfileCache?

    var body: some View {
        AvatarView(spec: avatarSpec, size: .small, showsNameAndTitle: false)
    }

    private var avatarSpec: AvatarRenderSpec {
        guard let cache = profileCache else {
            return AvatarRenderSpec(
                preset: nil,
                customAvatarImageData: nil,
                avatarEmoji: nil,
                displayName: "Hero",
                levelTitle: "Hero",
                equippedAccessory: nil,
                avatarClass: nil,
                role: .hero
            )
        }

        let preset: AvatarPreset? = if let id = cache.avatarName {
            AvatarPreset(rawValue: id) ?? AvatarPreset.resolve(cache.avatarClassEnum, id: id)
        } else if let cls = cache.avatarClassEnum {
            AvatarPreset.presets(for: cls).first
        } else {
            nil
        }

        return AvatarRenderSpec(
            preset: preset,
            customAvatarImageData: cache.customAvatarImageData,
            avatarEmoji: cache.avatarEmoji,
            displayName: cache.displayName,
            levelTitle: XPService.title(forLevel: cache.level),
            equippedAccessory: nil,
            avatarClass: cache.avatarClassEnum,
            role: cache.roleEnum ?? .hero
        )
    }
}
