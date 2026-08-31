//
//  FamilyScopeValidator.swift
//  LootList
//
//  Created by Ben Mackin on 8/30/26.
//

import os
import SwiftUI

// WHY: Family-scoped queries fail closed on empty scope; centralize DEBUG assert + warning.
enum FamilyScopeValidator {
    // WHY: Empty predicate silently returns zero rows and masks stale-cache reads.
    static func assertNonEmpty(targetFamily: String, viewName: String) {
        #if DEBUG
            assert(!targetFamily.isEmpty || TestEnvironment.isRunningUnitOrUITests, "\(viewName): empty familyRecordName — predicate will match no rows (fail-closed)")
        #endif
    }

    // WHY: Authenticated nil scope yields empty queries; surface warning for diagnostics.
    @MainActor
    static func warnIfNilFamily(familyRecordName: String?, appState: AppState, logger: Logger, viewName: String) {
        if familyRecordName == nil, appState.authStatus == .authenticated || appState.family != nil {
            logger.warning("\(viewName) initialized with nil familyRecordName while authenticated — queries scoped to empty string will return zero rows (fail-closed)")
        }
    }
}

extension View {
    // WHY: Reuse family-scope warning without duplicating logger branching in each view.
    @MainActor
    func familyScopeWarning(familyRecordName: String?, appState: AppState, logger: Logger, viewName: String) -> some View {
        onAppear {
            FamilyScopeValidator.warnIfNilFamily(familyRecordName: familyRecordName, appState: appState, logger: logger, viewName: viewName)
        }
    }
}
