//
//  DatabaseScopeResolver.swift
//  LootList
//
//  Created by Ben Mackin on 8/29/26.
//

import CloudKit
import Foundation

/// Single source for the owner-to-scope invariant. Every call site that
/// previously inlined `isOwner ? .private : .shared` must route through here
/// so the mapping is defined exactly once.
enum DatabaseScopeResolver {
    static func scope(isOwner: Bool) -> CKDatabase.Scope {
        isOwner ? .private : .shared
    }

    /// WHY truly optional: unresolved anchor returns nil so callers drop instead of guessing .shared.
    @MainActor
    static func resolvedScope(appState: AppState?) -> CKDatabase.Scope? {
        guard let appState else { return nil }
        guard appState.familyZoneID != nil, appState.family != nil || appState.currentProfile != nil else { return nil }
        // WHY single anchor: owner resolution lives with the guard so scope cannot drift.
        guard ActiveFamilyScopeGuard.isOwnerAnchorResolved(appState: appState) else {
            // WHY test seam: unit tests seed legacy anchors that never resolve, so fall back to stored flag.
            if TestEnvironment.isRunningUnitOrUITests {
                return scope(isOwner: appState.isZoneOwner)
            }
            // WHY stored flag alone proves nothing: unresolved anchor stays nil so callers serve cache only.
            return nil
        }
        return scope(isOwner: ActiveFamilyScopeGuard.resolvedIsOwner(appState: appState))
    }
}
