//
//  RPGFlagGate.swift
//  LootList
//
//  Created by Ben Mackin on 10/18/26.
//

import Foundation
@testable import LootList

/// Shared test gate for the device-local `FeatureFlags.rpgImmersive` toggle.
///
/// WHY one gate: Swift Testing runs suites concurrently, and the RPG flag is a
/// process-global UserDefaults value — unsynchronized toggles race across
/// suites and flake assertions. The gate serializes each read → set → body →
/// restore span on one key so only one suite toggles the flag at a time.
@MainActor
enum RPGFlagGate {
    private static let lock = KeyedAsyncLock()

    /// Saves and restores the device-local RPG flag while holding the shared
    /// gate, so concurrent suites never observe each other's toggle.
    static func withRPGFlag(_ enabled: Bool, _ body: () async throws -> Void) async throws {
        try await lock.withLock(key: "featureflags.rpgImmersive") {
            let original = FeatureFlags.rpgImmersive
            defer { FeatureFlags.rpgImmersive = original }
            FeatureFlags.rpgImmersive = enabled
            try await body()
        }
    }
}
