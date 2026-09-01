//
//  FamilyScopeValidator.swift
//  LootList
//
//  Created by Ben Mackin on 8/30/26.
//

/// Centralized debug assertion verifying that family-scoped views have a valid non-empty scope.
enum FamilyScopeValidator {
    static func assertNonEmpty(targetFamily: String, viewName: String) {
        #if DEBUG
            assert(!targetFamily.isEmpty || TestEnvironment.isRunningUnitOrUITests, "\(viewName): empty familyRecordName — predicate will match no rows (fail-closed)")
        #endif
    }
}
