//
//  TestEnvironment.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation
import SwiftUI

/// Deterministic launch scenarios for UI test runs, selected with
/// `--uitest-seed=<rawValue>`. Every scenario implies `--uitesting` and seeds
/// through `SampleData`, so repeated launches render identical state.
enum UITestScenario: String, CaseIterable {
    /// Welcome screen with no authenticated session.
    case freshOnboarding = "onboarding"
    /// Authenticated Guild Master over the standard seeded family.
    case seededParent = "parent"
    /// Authenticated hero with buckets, goals, and a pending parent review.
    case seededChild = "child"
    /// Seeded child plus board quests where the first entries are already
    /// claimed, so HeroBoardView renders both sections deterministically.
    case heroBoardWithClaims = "hero-board"
}

enum TestEnvironment {
    static var isRunningUnitOrUITests: Bool {
        // XCTestConfigurationFilePath is set in processes run by Xcode test runners
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return true
        }

        // When UI tests run the XCTest framework is loaded into the app process;
        // checking for XCTestCase presence is a common technique.
        if NSClassFromString("XCTestCase") != nil {
            return true
        }

        // Custom launch arguments passed during XCUI test runs
        if CommandLine.arguments.contains("--uitesting") || CommandLine.arguments.contains("--skip-cloudkit") {
            return true
        }

        return false
    }

    /// True only when the app was launched by an XCUI test runner with the
    /// explicit `--uitesting` argument. Unit tests do not pass launch
    /// arguments, so flag forcing and scenario seeding stay UI-test-only.
    static var isRunningUITests: Bool {
        CommandLine.arguments.contains("--uitesting")
    }

    /// The scenario selected via `--uitest-seed=<name>`. Falls back to the
    /// legacy bare flags (`--onboarding`, `--parent`) so pre-existing suites
    /// keep their behavior, and finally to the seeded child default. Unknown
    /// seed values degrade to that same default rather than crashing a run.
    static var activeScenario: UITestScenario? {
        guard isRunningUITests else { return nil }

        let seedPrefix = "--uitest-seed="
        if let seedArgument = CommandLine.arguments.first(where: { $0.hasPrefix(seedPrefix) }),
           let scenario = UITestScenario(rawValue: String(seedArgument.dropFirst(seedPrefix.count)))
        {
            return scenario
        }

        if CommandLine.arguments.contains("--onboarding") {
            return .freshOnboarding
        }
        if CommandLine.arguments.contains("--parent") {
            return .seededParent
        }
        return .seededChild
    }

    /// Appearance forced via `--uitest-appearance=<light|dark>`, letting one
    /// simulator capture both modes without reconfiguring the OS setting.
    static var preferredAppearanceOverride: ColorScheme? {
        let prefix = "--uitest-appearance="
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix(prefix) }) else {
            return nil
        }
        switch String(argument.dropFirst(prefix.count)).lowercased() {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    /// CSV file handed straight to the ledger import staging view when
    /// launched with `--uitest-import-csv=<path>`. The system document picker
    /// cannot be driven deterministically from XCUITest, so UI tests write a
    /// sample file to a simulator-shared path and pass it here instead.
    static var uiTestImportCSVPath: String? {
        guard isRunningUITests else { return nil }
        let prefix = "--uitest-import-csv="
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix(prefix) }) else {
            return nil
        }
        return String(argument.dropFirst(prefix.count))
    }

    /// When running in unprovisioned headless CI environments without signed iCloud
    /// entitlements or when `--skip-cloudkit` is passed, tests that instantiate
    /// `CKSyncEngine` can check this flag to safely bypass container entitlement validation.
    static var shouldSkipLiveCloudKitEngineTests: Bool {
        // In any unit-test process the iCloud container `iCloud.com.volcrypt.lootlist`
        // is unentitled (no `com.apple.developer.icloud-container-identifiers`
        // in the test host). Creating a real `CKSyncEngine` there spams
        // `xpcActivity`/`accountChange` logs and can trigger real CloudKit
        // fetches that crash in CI. Default to skipping live engines in tests.
        isRunningUnitOrUITests
            || CommandLine.arguments.contains("--skip-cloudkit")
            || ProcessInfo.processInfo.environment["SKIP_CLOUDKIT_TESTS"] != nil
    }
}
