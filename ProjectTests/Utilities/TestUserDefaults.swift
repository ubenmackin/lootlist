//
//  TestUserDefaults.swift
//  LootListTests
//
//  Created by Ben Mackin on 8/23/26.
//

import Foundation
@testable import LootList

extension UserDefaults {
    /// Creates an isolated ephemeral `UserDefaults` instance unique to the calling test/suite.
    static func ephemeral(suite: String = #file, function: String = #function) -> UserDefaults {
        let suiteBase = (suite as NSString).lastPathComponent.replacingOccurrences(of: ".swift", with: "")
        let suiteName = "test.\(suiteBase).\(function).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create isolated UserDefaults with suite: \(suiteName)")
        }
        return defaults
    }
}

extension AppState {
    /// Creates an AppState configured with an ephemeral, isolated UserDefaults suite.
    static func testState(defaults: UserDefaults = .ephemeral()) -> AppState {
        AppState(defaults: defaults)
    }
}
