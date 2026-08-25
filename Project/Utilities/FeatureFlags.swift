//
//  FeatureFlags.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import Foundation

/// Device-local feature toggles. Flags hide UI surfaces only — the code behind
/// them remains compiled and functional so any surface can be switched back on
/// without recovery work.
enum FeatureFlags {
    private static let rpgImmersiveDefaultsKey = "featureflags.rpgImmersive"

    /// Toggles the fantasy-RPG presentation layer (sprite avatars, Hero classes,
    /// leveling, quest rarity, journey path, mascots, gems, gear, loot drops,
    /// daily login rewards). Off by default so the app leads with its
    /// utility-first experience; underlying services keep running untouched.
    static var rpgImmersive: Bool {
        get { UserDefaults.standard.bool(forKey: rpgImmersiveDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: rpgImmersiveDefaultsKey) }
    }
}
