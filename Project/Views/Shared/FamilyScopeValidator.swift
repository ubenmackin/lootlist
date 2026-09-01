//
//  FamilyScopeValidator.swift
//  LootList
//
//  Created by Ben Mackin on 8/30/26.

import Foundation
import os
import Synchronization

/// Centralized debug assertion verifying that family-scoped views have a valid non-empty scope.
enum FamilyScopeValidator {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LootList", category: "FamilyScopeValidator")
    private static let emittedFaults = Mutex<Set<String>>(Set<String>())

    static func assertNonEmpty(targetFamily: String, viewName: String) {
        #if DEBUG
            assert(!targetFamily.isEmpty || TestEnvironment.isRunningUnitOrUITests, "\(viewName): empty familyRecordName — predicate will match no rows (fail-closed)")
        #endif
    }

    static func validateOrFault(targetFamily: String, viewName: String) {
        assertNonEmpty(targetFamily: targetFamily, viewName: viewName)
        // WHY: empty is expected during bootstrap (nil -> "" fail-closed); gate + debounce fault to avoid cold-start spam and test noise.
        guard targetFamily.isEmpty else { return }
        guard !TestEnvironment.isRunningUnitOrUITests else { return }
        // WHY: Mutex protects the debounce set under Swift 6 strict concurrency.
        guard !emittedFaults.withLock({ $0.contains(viewName) }) else { return }
        emittedFaults.withLock { _ = $0.insert(viewName) }
        logger.fault("\(viewName, privacy: .public) init with empty family — returning 0 rows fail-closed")
    }
}
