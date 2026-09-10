//
//  FeatureFlags.swift
//  LootList
//
//  Created by Ben Mackin on 8/24/26.
//

import Foundation
import Observation
import SwiftUI

/// Device-local feature toggles. Flags hide UI surfaces only — the code behind
/// them remains compiled and functional so any surface can be switched back on
/// without recovery work.
enum FeatureFlags {
    fileprivate static let rpgImmersiveKey = "featureflags.rpgImmersive"

    /// Toggles the fantasy-RPG presentation layer (off by default for utility-first UI).
    static var rpgImmersive: Bool {
        get { UserDefaults.standard.bool(forKey: rpgImmersiveKey) }
        set { UserDefaults.standard.set(newValue, forKey: rpgImmersiveKey) }
    }
}

/// Observable counterpart to `FeatureFlags` for SwiftUI auto-refresh.
///
/// WHY observable store: the static reads UserDefaults on every access but never
/// notifies, so views reading `FeatureFlags.rpgImmersive` directly in `body`
/// keep stale chrome until relaunch. Views that read this store via the
/// environment (`@Environment(FeatureFlagsStore.self)`) refresh on toggle mid-run.
///
/// WHY shared key: the store persists through the same UserDefaults key that the
/// `@AppStorage("featureflags.rpgImmersive")` in settings views uses, so a toggle
/// from either surface converges on one value. External `@AppStorage` writes
/// bypass the store, so call `refreshFromDefaults()` on appear or after a
/// settings change to pull them in.
///
/// Inject via `.environment(FeatureFlagsStore())` at the root and read via
/// `@Environment(FeatureFlagsStore.self) var flags` alongside the static for
/// non-view code.
@MainActor
@Observable
final class FeatureFlagsStore {
    /// UserDefaults key shared with the `@AppStorage` settings toggle.
    static let rpgImmersiveDefaultsKey = FeatureFlags.rpgImmersiveKey

    var rpgImmersive: Bool {
        didSet {
            guard oldValue != rpgImmersive else { return }
            defaults.set(rpgImmersive, forKey: Self.rpgImmersiveDefaultsKey)
            FeatureFlags.rpgImmersive = rpgImmersive
        }
    }

    @ObservationIgnored
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.rpgImmersive = defaults.bool(forKey: Self.rpgImmersiveDefaultsKey)
    }

    /// Pulls external writes (e.g. a settings `@AppStorage` toggle) into the
    /// observed property so injected views refresh mid-run.
    func refreshFromDefaults() {
        let current = defaults.bool(forKey: Self.rpgImmersiveDefaultsKey)
        if current != rpgImmersive {
            rpgImmersive = current
        }
    }

    func setRPGImmersive(_ value: Bool) {
        rpgImmersive = value
    }
}
