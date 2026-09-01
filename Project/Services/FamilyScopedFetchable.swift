//
//  FamilyScopedFetchable.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import Foundation
import SwiftData

/// Marker refinement of ``FamilyScopedCache`` for types that support the
/// generic family-scoped fetch helper ``CacheService/fetchAll(_:family:)-6aggr``.
protocol FamilyScopedFetchable: FamilyScopedCache {}

// MARK: - Conformances

extension AchievementCache: FamilyScopedFetchable {}
extension AllowancePeriodCache: FamilyScopedFetchable {}
extension GemLedgerCache: FamilyScopedFetchable {}
extension GoalCache: FamilyScopedFetchable {}
extension LedgerEntryCache: FamilyScopedFetchable {}
extension NotificationPreferenceCache: FamilyScopedFetchable {}
extension ProfileAchievementCache: FamilyScopedFetchable {}
extension ProfileCache: FamilyScopedFetchable {}
extension QuestCache: FamilyScopedFetchable {}
extension QuestCompletionCache: FamilyScopedFetchable {}
extension QuestTemplateCache: FamilyScopedFetchable {}
extension RewardEventCache: FamilyScopedFetchable {}
