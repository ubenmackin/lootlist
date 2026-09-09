//
//  CacheFreshness.swift
//  LootList
//
//  Created by Ben Mackin on 9/9/26.
//

import Foundation

/// ViewModel-owned freshness Bools for empty-versus-loading gates.
/// WHY Bool vending: Views render Bool snapshots so scope resolution and
/// authority checks never cross into the View layer.
@MainActor
enum CacheFreshness {
    /// Scope-gated ledger hydration for the treasury empty state.
    /// WHY scope-gated: unresolved scope stays unhydrated instead of guessing a database.
    static func isLedgerFresh(familyRecordName: String, appState: AppState?) -> Bool {
        guard !familyRecordName.isEmpty else { return false }
        guard let scope = DatabaseScopeResolver.resolvedScope(appState: appState) else { return false }
        return appState?.cacheService?.isCacheFresh(familyRecordName: familyRecordName, type: .ledgerEntry, scope: scope) ?? false
    }

    /// Scope-gated profile hydration for the hub placeholder gates.
    /// WHY scope-gated: unresolved scope stays unhydrated instead of guessing a database.
    static func isProfileFresh(familyRecordName: String, appState: AppState?) -> Bool {
        guard !familyRecordName.isEmpty else { return false }
        guard let scope = DatabaseScopeResolver.resolvedScope(appState: appState) else { return false }
        return appState?.cacheService?.isCacheFresh(familyRecordName: familyRecordName, type: .profile, scope: scope) ?? false
    }

    /// Per-type trophy authority backing the profile hydration gate.
    struct ProfileAuthority: Sendable, Equatable {
        let earned: Bool
        let definitions: Bool
    }

    /// Scope-gated trophy authority; nil when scope is unresolved.
    /// WHY fail-closed: unknown scope stays cache-only without guessing a database.
    static func profileAuthority(profile: Profile, family: Family?, cache: any CacheServicing, appState: AppState?) -> ProfileAuthority? {
        guard let scope = DatabaseScopeResolver.resolvedScope(appState: appState) else { return nil }
        let earned = cache.isCacheAuthoritative(familyRecordName: profile.family.recordID.recordName, type: .profileAchievement, scope: scope)
        let definitions = family.map { cache.isCacheAuthoritative(familyRecordName: $0.id.recordName, type: .achievement, scope: scope) } ?? true
        return ProfileAuthority(earned: earned, definitions: definitions)
    }
}
