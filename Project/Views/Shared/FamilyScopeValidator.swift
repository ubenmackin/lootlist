//
//  FamilyScopeValidator.swift
//  LootList
//
//  Created by Ben Mackin on 8/30/26.
//

// WHY: Family-scoped queries fail closed on empty scope; centralize DEBUG assert.
enum FamilyScopeValidator {
    // WHY: Empty predicate silently returns zero rows and masks stale-cache reads.
    static func assertNonEmpty(targetFamily: String, viewName: String) {
        #if DEBUG
            assert(!targetFamily.isEmpty || TestEnvironment.isRunningUnitOrUITests, "\(viewName): empty familyRecordName — predicate will match no rows (fail-closed)")
        #endif
    }
}
