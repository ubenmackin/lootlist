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

    /// Toggles the fantasy-RPG presentation layer (off by default for utility-first UI).
    static var rpgImmersive: Bool {
        get { UserDefaults.standard.bool(forKey: rpgImmersiveDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: rpgImmersiveDefaultsKey) }
    }
}
