//
//  CachedRecordType.swift
//  LootList
//
//  Typed representation of every CloudKit entity that has a local SwiftData
//  cache row. Resolving a raw `CKRecord.RecordType` string through this enum
//  (rather than switching on string literals) hardens the delete path against
//  Swift class-name / CKRecordType divergence — e.g. `QuestCompletion`
//  (`recordType == "QuestLog"` while the Swift type is named `QuestCompletion`).
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
        }
    }

    static func recordType(for ckRecordType: CKRecord.RecordType) -> CachedRecordType? {
        allCases.first { $0.ckRecordType == ckRecordType }
    }
}
