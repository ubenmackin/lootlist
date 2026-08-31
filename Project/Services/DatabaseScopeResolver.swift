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
}
