//
//  AchievementService+CacheAuthority.swift
//  LootList
//
//  Created by Ben Mackin on 9/9/26.
//

import Foundation

/// WHY service owns scope: Views read a Bool so database scope never crosses into the View layer.
extension AchievementService {
    /// WHY fail-closed: unknown scope serves cache only without guessing a database.
    func isAchievementCacheAuthoritative(familyRecordName: String) -> Bool {
        guard let scope = DatabaseScopeResolver.resolvedScope(appState: appState) else {
            return false
        }
        guard let cache = cacheService else {
            return false
        }
        return cache.isCacheAuthoritative(familyRecordName: familyRecordName, type: .achievement, scope: scope)
    }
}
