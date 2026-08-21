//
//  TestEnvironment.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation

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
