//
//  CachedRecordType.swift
//  LootList
//
//  Created by Ben Mackin on 7/21/26.
//

import CloudKit
import Foundation

enum CachedRecordType: String, CaseIterable, Sendable {
    case profile
    case family
    case quest
    case questTemplate
    case questCompletion
    case ledgerEntry
    case allowancePeriod
    case achievement
    case profileAchievement
    case notificationPreference
    case gemLedger
    case rewardEvent

    // MARK: - Scope Split

    /// Database scopes from which this record type can be fetched.
    /// All family-zone types are logically zone-bound and exist in both the
    /// owner's private database and the participant's shared database. Freshness
    /// is therefore tracked per-scope in `CacheService` so a `CKSyncEngine`
    /// pass that only fetched `.private` never marks shared data as fresh.
    /// Callers that gate cache-first reads should use the scope-aware
    /// `CacheService.isCacheFresh(familyRecordName:type:scope:)` overload with
    /// the database scope that owns the active family zone (`isZoneOwner ?
    /// .private : .shared`). `CKSyncEngineCoordinator.stampCacheFreshness`
    /// only stamps the scopes that actually completed in the current pass.
    var fetchScopes: Set<CKDatabase.Scope> {
        // Currently every family-zone type is fetchable from both scopes; the
        // distinction is which DB holds the active zone. If a future type
        // becomes scope-specific (e.g. private-only ledger), narrow its set
        // here and the stamping gate will automatically respect it.
        [.private, .shared]
    }

    /// Convenience for the common case: required scope is the active zone's DB.
    /// When `isZoneOwner` is true the required scope is `.private`, otherwise
    /// `.shared`. `CKSyncEngineCoordinator` uses `fetchScopes` to filter types
    /// whose required scope was actually fetched before stamping.
    static func requiredScope(isZoneOwner: Bool) -> CKDatabase.Scope {
        isZoneOwner ? .private : .shared
    }

    var ckRecordType: CKRecord.RecordType {
        switch self {
        case .profile: Profile.recordType
        case .family: Family.recordType
        case .quest: Quest.recordType
        case .questTemplate: QuestTemplate.recordType
        case .questCompletion: QuestCompletion.recordType
        case .ledgerEntry: LedgerEntry.recordType
        case .allowancePeriod: AllowancePeriod.recordType
        case .achievement: Achievement.recordType
        case .profileAchievement: ProfileAchievement.recordType
        case .notificationPreference: NotificationPreference.recordType
        case .gemLedger: GemLedger.recordType
        case .rewardEvent: RewardEvent.recordType
        }
    }

    static func recordType(for ckRecordType: CKRecord.RecordType) -> CachedRecordType? {
        allCases.first { $0.ckRecordType == ckRecordType }
    }
}
